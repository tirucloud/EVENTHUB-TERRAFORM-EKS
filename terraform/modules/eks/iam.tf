# ------------------------------------------------------------------------------
# Control plane role
#
# Assumed by the EKS service itself so it can manage ENIs, load balancers and
# other AWS resources on the cluster's behalf.
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.cluster_name}-cluster-role"
  description        = "EKS control plane role for ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    # Lets the control plane manage ENIs for pods that use security groups.
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ------------------------------------------------------------------------------
# Node role
#
# Assumed by the EC2 instances. Note what is deliberately absent: no S3 access,
# no Route53 access, no EBS volume permissions. Workloads that need AWS APIs get
# them through IRSA instead, so a compromised pod cannot borrow the node's
# identity to reach services it was never meant to touch.
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name               = "${var.cluster_name}-node-role"
  description        = "EKS worker node role for ${var.cluster_name}"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    # Register with the cluster and report node status.
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    # The VPC CNI allocates pod IPs from the node's ENIs. This could be moved to
    # IRSA for tighter scoping; it is on the node role here to keep the
    # bootstrap order simple.
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    # Pull images from the EventHub ECR repository.
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    # Shell access through SSM Session Manager, so no SSH key or port 22 rule
    # is needed to debug a node.
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# ------------------------------------------------------------------------------
# OIDC identity provider
#
# Registering the cluster's OIDC issuer with IAM is what makes IRSA possible.
# Every role built by the irsa module trusts this provider.
# ------------------------------------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(var.tags, { Name = "${var.cluster_name}-oidc" })
}
