# EKS control plane, node group and cluster access configuration.

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# Secrets encryption
#
# Without this, Kubernetes Secrets are stored base64-encoded in etcd, which is
# encoding rather than encryption. This adds a KMS envelope key on top.
# ------------------------------------------------------------------------------

resource "aws_kms_key" "eks" {
  count = var.enable_secrets_encryption ? 1 : 0

  description             = "Envelope encryption key for ${var.cluster_name} Kubernetes secrets"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(var.tags, { Name = "${var.cluster_name}-secrets" })
}

resource "aws_kms_alias" "eks" {
  count = var.enable_secrets_encryption ? 1 : 0

  name          = "alias/${var.cluster_name}-secrets"
  target_key_id = aws_kms_key.eks[0].key_id
}

# ------------------------------------------------------------------------------
# Control plane logs
#
# Created explicitly so retention is bounded. If EKS creates this group itself
# it defaults to "never expire", which quietly accrues cost forever.
# ------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Control plane ENIs live in the private subnets only. Load balancer
    # placement is decided by the kubernetes.io/role/* subnet tags, not by this
    # list, so public subnets do not need to appear here.
    subnet_ids = var.private_subnet_ids

    # Always on: nodes and in-VPC clients reach the API server without leaving
    # the VPC.
    endpoint_private_access = true

    # Public access is what lets kubectl work from a laptop. Narrow
    # public_access_cidrs to your own address for anything long-lived.
    endpoint_public_access = var.endpoint_public_access
    public_access_cidrs    = var.public_access_cidrs

    security_group_ids = var.additional_security_group_ids
  }

  access_config {
    # API_AND_CONFIG_MAP keeps the legacy aws-auth ConfigMap working while
    # access entries do the real work. Access entries are the modern mechanism:
    # they are ordinary AWS resources, so a typo fails the apply instead of
    # silently locking everyone out of the cluster the way a bad aws-auth edit
    # used to.
    authentication_mode = "API_AND_CONFIG_MAP"

    # The principal running this apply becomes a cluster admin.
    bootstrap_cluster_creator_admin_permissions = true
  }

  # api and audit are the two that answer "who did this and when". The rest are
  # cheap and occasionally invaluable when the cluster misbehaves.
  enabled_cluster_log_types = var.enabled_log_types

  dynamic "encryption_config" {
    for_each = var.enable_secrets_encryption ? [1] : []

    content {
      provider {
        key_arn = aws_kms_key.eks[0].arn
      }
      resources = ["secrets"]
    }
  }

  tags = merge(var.tags, { Name = var.cluster_name })

  # Without these, the cluster can start creating before its role has the
  # permissions it needs, and the apply fails in a confusing way.
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.cluster,
  ]
}

# ------------------------------------------------------------------------------
# Node launch template
#
# A launch template is not strictly required for a managed node group, but it is
# the only way to attach an extra security group, enforce IMDSv2, or encrypt the
# root volume.
# ------------------------------------------------------------------------------

resource "aws_launch_template" "nodes" {
  name_prefix = "${var.cluster_name}-node-"
  description = "Launch template for ${var.cluster_name} worker nodes"

  # Note what is NOT set: image_id and user_data. Leaving them out lets EKS
  # inject the correct AMI for ami_type and generate the bootstrap script.
  # Setting image_id here would make this template responsible for bootstrapping
  # the node, which is a much larger commitment than it looks.

  vpc_security_group_ids = concat(
    # This one is essential. When a launch template specifies security groups,
    # EKS stops attaching the cluster security group automatically — and
    # without it, nodes cannot reach the control plane and never join.
    [aws_eks_cluster.this.vpc_config[0].cluster_security_group_id],
    var.node_security_group_ids,
  )

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.node_disk_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  metadata_options {
    http_endpoint = "enabled"
    # IMDSv2 only. Session-oriented tokens make the metadata service far harder
    # to reach through a server-side request forgery bug in a pod.
    http_tokens = "required"
    # 2 is the EKS default and is what non-host-network pods need to reach IMDS.
    # Setting it to 1 confines IMDS to host processes, which is stricter and
    # works well once every workload uses IRSA.
    http_put_response_hop_limit = 2
  }

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  tag_specifications {
    resource_type = "instance"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node" })
  }

  tag_specifications {
    resource_type = "volume"
    tags          = merge(var.tags, { Name = "${var.cluster_name}-node-volume" })
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# ------------------------------------------------------------------------------
# Managed node group
# ------------------------------------------------------------------------------

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-${var.node_group_name}"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = var.node_capacity_type
  ami_type       = var.node_ami_type

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    # During a node group update, replace at most a third of the nodes at once.
    max_unavailable_percentage = 33
  }

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  labels = merge(
    { "eventhub.io/node-group" = var.node_group_name },
    var.node_labels,
  )

  tags = var.tags

  lifecycle {
    # Cluster Autoscaler owns desired_size once the cluster is running. Without
    # this, every `terraform apply` would reset the node count to the value in
    # tfvars and undo whatever scaling decision the autoscaler just made.
    ignore_changes = [scaling_config[0].desired_size]
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}

# ------------------------------------------------------------------------------
# Cluster Autoscaler discovery tags
#
# Cluster Autoscaler finds the groups it may scale by looking for these two tags
# on the ASG. EKS does not add them to a managed node group's ASG, so they are
# set here explicitly. Miss them and the autoscaler runs happily while ignoring
# every node group — the failure mode is silence, not an error.
# ------------------------------------------------------------------------------

resource "aws_autoscaling_group_tag" "autoscaler_enabled" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "autoscaler_cluster" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.cluster_name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

# ------------------------------------------------------------------------------
# Cluster access
#
# One access entry per principal that should be able to run kubectl. The apply
# principal already has admin from bootstrap_cluster_creator_admin_permissions;
# these cover teammates.
# ------------------------------------------------------------------------------

resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_principal_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
