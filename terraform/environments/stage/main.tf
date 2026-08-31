# ==============================================================================
# EventHub — one environment, applied in stages
# ==============================================================================
#
# Every module for this environment lives in this one root. The first run is
# staged with -target so that AWS infrastructure is built before anything tries
# to talk to the cluster:
#
#   1  terraform apply -target=module.vpc
#   2  terraform apply -target=module.security_groups
#   3  terraform apply -target=module.ecr
#   4  terraform apply -target=module.route53
#   5  terraform apply -target=module.eks
#   6  terraform apply -target=module.irsa_ebs_csi_driver \
#                      -target=module.irsa_cluster_autoscaler \
#                      -target=module.irsa_cert_manager \
#                      -target=module.irsa_aws_load_balancer_controller
#   7  terraform apply -target=module.eks_addons
#
#   --- infrastructure is ready; now build and push the images ---
#      the GitHub Actions pipeline, or `make ecr-push`
#
#   8  terraform apply -target=module.cert_manager
#   9  terraform apply -target=module.traefik
#  10  terraform apply -target=module.k8s_app
#
# After that first pass everything is in state, so a plain `terraform apply`
# works and is what you use from then on.
#
# `make dev-infra` runs steps 1-7 and `make dev-apps` runs 8-10.
# ==============================================================================

data "aws_caller_identity" "current" {}

locals {
  name         = "${var.project}-${var.environment}"
  cluster_name = "${local.name}-eks"
  # An empty subdomain serves the application from the zone apex. Possible
  # only because the traefik module publishes Route53 ALIAS records; a CNAME
  # is illegal at an apex.
  app_fqdn = var.subdomain == "" ? var.domain_name : "${var.subdomain}.${var.domain_name}"

  # Named rather than read from module.cert_manager's output on purpose.
  # Referencing that output would make module.k8s_app depend on the whole
  # cert-manager module, and `-target` pulls dependencies in with it — so
  # deploying the application would silently install cert-manager too. These are
  # fixed strings the cert-manager module also uses, so nothing can drift.
  cluster_issuer = var.use_letsencrypt_staging ? "letsencrypt-staging" : "letsencrypt-prod"

  tags = {
    Project     = var.project
    Environment = var.environment
    Cluster     = local.cluster_name
  }
}

# ==============================================================================
# STAGE 1-4 — network, registry and DNS
# ==============================================================================

module "vpc" {
  source = "../../modules/vpc"

  name                    = local.name
  cluster_name            = local.cluster_name
  vpc_cidr                = var.vpc_cidr
  availability_zone_count = var.availability_zone_count
  single_nat_gateway      = var.single_nat_gateway
  enable_flow_logs        = var.enable_flow_logs

  tags = local.tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  name          = local.name
  vpc_id        = module.vpc.vpc_id
  vpc_cidr      = module.vpc.vpc_cidr_block
  ingress_cidrs = var.allowed_lb_ingress_cidrs

  tags = local.tags
}

module "ecr" {
  source = "../../modules/ecr"

  repository_name    = var.ecr_repository_name
  services           = var.services
  images_per_service = var.images_per_service
  force_delete       = var.ecr_force_delete

  tags = local.tags
}

# One hosted zone is shared by all three environments, distinguished by
# subdomain. Whichever environment you build first should set
# create_route53_zone = true; the others look the same zone up.
module "route53" {
  source = "../../modules/route53"

  domain_name = var.domain_name
  subdomain   = var.subdomain
  create_zone = var.create_route53_zone

  tags = local.tags
}

# ==============================================================================
# STAGE 5 — the cluster
# ==============================================================================

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  kubernetes_version = var.kubernetes_version
  private_subnet_ids = module.vpc.private_subnet_ids

  additional_security_group_ids = [module.security_groups.cluster_security_group_id]
  node_security_group_ids       = [module.security_groups.node_security_group_id]

  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs

  node_instance_types = var.node_instance_types
  node_capacity_type  = var.node_capacity_type
  node_desired_size   = var.node_desired_size
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_disk_size      = var.node_disk_size

  cluster_admin_principal_arns = var.cluster_admin_principal_arns

  tags = local.tags
}

# ==============================================================================
# STAGE 6 — IRSA roles
#
# One role per controller that calls AWS, each scoped to the exact service
# account that uses it and the narrowest set of actions that works.
# ==============================================================================

module "irsa_ebs_csi_driver" {
  source = "../../modules/irsa"

  role_name         = "${local.cluster_name}-ebs-csi-driver"
  description       = "EBS CSI driver for ${local.cluster_name}"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  service_accounts = [{
    namespace = "kube-system"
    name      = "ebs-csi-controller-sa"
  }]

  policy_arns = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]

  tags = local.tags
}

module "irsa_cluster_autoscaler" {
  source = "../../modules/irsa"

  role_name         = "${local.cluster_name}-cluster-autoscaler"
  description       = "Cluster Autoscaler for ${local.cluster_name}"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  service_accounts = [{
    namespace = "kube-system"
    name      = "cluster-autoscaler"
  }]

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadScalingState"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        # Mutating actions are conditioned on the ASG carrying the
        # k8s.io/cluster-autoscaler/<cluster> = owned tag the eks module sets,
        # so this role cannot resize an unrelated ASG in the same account.
        Sid    = "ScaleOwnedNodeGroups"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}" = "owned"
          }
        }
      },
    ]
  })

  tags = local.tags
}

module "irsa_cert_manager" {
  source = "../../modules/irsa"

  role_name         = "${local.cluster_name}-cert-manager"
  description       = "cert-manager DNS-01 solver for ${local.cluster_name}"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  service_accounts = [{
    namespace = "cert-manager"
    name      = "cert-manager"
  }]

  inline_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "WaitForChangePropagation"
        Effect   = "Allow"
        Action   = "route53:GetChange"
        Resource = "arn:aws:route53:::change/*"
      },
      {
        Sid      = "WriteChallengeRecords"
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = [module.route53.zone_arn]
      },
      {
        Sid      = "FindHostedZone"
        Effect   = "Allow"
        Action   = "route53:ListHostedZonesByName"
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

module "irsa_aws_load_balancer_controller" {
  source = "../../modules/irsa"

  role_name         = "${local.cluster_name}-aws-lb-controller"
  description       = "AWS Load Balancer Controller for ${local.cluster_name}"
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url

  service_accounts = [{
    namespace = "kube-system"
    name      = "aws-load-balancer-controller"
  }]

  # AWS's published policy for the controller, unmodified. Long enough to
  # deserve its own file.
  inline_policy_json = file("${path.module}/../../modules/irsa/policies/aws-load-balancer-controller.json")

  tags = local.tags
}

# ==============================================================================
# STAGE 7 — add-ons and cluster controllers
# ==============================================================================

module "eks_addons" {
  source = "../../modules/eks-addons"

  cluster_name       = module.eks.cluster_name
  kubernetes_version = module.eks.cluster_version
  aws_region         = var.aws_region
  vpc_id             = module.vpc.vpc_id

  ebs_csi_driver_role_arn = module.irsa_ebs_csi_driver.role_arn
  enable_metrics_server   = var.enable_metrics_server

  enable_aws_load_balancer_controller        = true
  aws_load_balancer_controller_role_arn      = module.irsa_aws_load_balancer_controller.role_arn
  aws_load_balancer_controller_chart_version = var.aws_load_balancer_controller_chart_version

  enable_cluster_autoscaler        = var.enable_cluster_autoscaler
  cluster_autoscaler_role_arn      = module.irsa_cluster_autoscaler.role_arn
  cluster_autoscaler_chart_version = var.cluster_autoscaler_chart_version

  tags = local.tags
}

# ==============================================================================
# STAGE 8 — TLS
# ==============================================================================

module "cert_manager" {
  source = "../../modules/cert-manager"

  chart_version = var.cert_manager_chart_version
  irsa_role_arn = module.irsa_cert_manager.role_arn

  acme_email    = var.acme_email
  aws_region    = var.aws_region
  dns_zone_id   = module.route53.zone_id
  dns_zone_name = module.route53.domain_name

  depends_on = [module.eks_addons]
}

# ==============================================================================
# STAGE 9 — ingress
# ==============================================================================

module "traefik" {
  source = "../../modules/traefik"

  cluster_name                    = module.eks.cluster_name
  chart_version                   = var.traefik_chart_version
  replicas                        = var.traefik_replicas
  load_balancer_security_group_id = module.security_groups.load_balancer_security_group_id

  # Off until TLS actually works. With the redirect on and no certificate yet,
  # every plain HTTP request 308s to an HTTPS URL that does not resolve, which
  # makes the application impossible to test before DNS delegation. Turned on in
  # the same step that turns on TLS.
  redirect_http_to_https = var.traefik_redirect_http_to_https

  dns_zone_id = module.route53.zone_id
  hostnames   = [local.app_fqdn]

  depends_on = [module.eks_addons]
}

# ==============================================================================
# STAGE 10 — the application
# ==============================================================================

module "k8s_app" {
  source = "../../modules/k8s-app"

  namespace   = var.app_namespace
  environment = var.environment

  ecr_repository_url = module.ecr.repository_url
  image_tag          = var.image_tag
  image_pull_policy  = var.image_pull_policy

  replicas               = var.app_replicas
  enable_hpa             = var.enable_hpa
  hpa_min_replicas       = var.hpa_min_replicas
  hpa_max_replicas       = var.hpa_max_replicas
  hpa_cpu_target_percent = var.hpa_cpu_target_percent

  app_fqdn           = local.app_fqdn
  ingress_class_name = module.traefik.ingress_class_name
  enable_tls         = var.enable_tls
  cluster_issuer     = local.cluster_issuer

  log_level                    = var.log_level
  payment_failure_rate_percent = var.payment_failure_rate_percent

  postgres_storage_size = var.postgres_storage_size
  postgres_image        = var.postgres_image

  # cert-manager is deliberately absent. The application is deployable without
  # it — the frontend Ingress simply carries an annotation nothing is watching
  # yet, and cert-manager picks it up whenever it is installed. Listing it here
  # would mean `-target=module.k8s_app` installed cert-manager as a side effect.
  depends_on = [
    module.eks_addons,
    module.traefik,
  ]
}

# ==============================================================================
# Optional — GitHub Actions OIDC, replacing the static CI credentials
#
# Off by default. The OIDC provider is account-wide, so enable it in one
# environment only; the others should set github_oidc_create_provider = false.
# ==============================================================================

module "github_oidc" {
  source = "../../modules/github-oidc"
  count  = var.enable_github_oidc ? 1 : 0

  github_owner         = var.github_owner
  github_repository    = var.github_repository
  role_name            = "${local.name}-github-actions"
  ecr_repository_arn   = module.ecr.repository_arn
  create_oidc_provider = var.github_oidc_create_provider

  tags = local.tags
}
