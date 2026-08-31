# ==============================================================================
# prod — the settings that cost money, and the ones that matter
#
# Everything here that differs from dev is a deliberate trade: pay more, get
# resilience. Read the comments before copying this into a real production
# account, because three things below are still marked TODO.
# ==============================================================================

aws_region  = "us-east-1"
project     = "eventhub"
environment = "prod"

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

vpc_cidr                = "10.2.0.0/16"
availability_zone_count = 3

# One NAT gateway per availability zone. Roughly $99/month instead of $33, and
# worth every rupee here: with a single NAT, losing that one zone takes out
# outbound traffic for the whole cluster, and every cross-AZ byte is billed as
# inter-AZ transfer.
single_nat_gateway = false

# Flow logs on. When something is unreachable at 2am, the difference between a
# security group problem and a routing problem is one query away.
enable_flow_logs = true

# TODO before this is genuinely production: restrict this to your office or VPN
# range so the application is not open to the entire internet.
allowed_lb_ingress_cidrs = ["0.0.0.0/0"]

# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

kubernetes_version = "1.35"

# Two instance types rather than one. If AWS has no t3.large capacity in a zone,
# the node group can still scale using m5.large instead of leaving pods Pending.
node_instance_types = ["t3.large", "m5.large"]
node_capacity_type  = "ON_DEMAND"

# Three nodes minimum, one per AZ, so a single node failure never takes a whole
# zone's workload with it.
node_desired_size = 3
node_min_size     = 3
node_max_size     = 10
node_disk_size    = 50

# TODO before this is genuinely production: set this to false and reach the API
# through a VPN or bastion, or at minimum narrow public_access_cidrs to known
# addresses. A public Kubernetes API endpoint open to 0.0.0.0/0 is the single
# largest exposure in this file.
endpoint_public_access = true
public_access_cidrs    = ["0.0.0.0/0"]

# TODO: list the people and CI roles that need kubectl. Relying on whoever ran
# the last apply is not an access model.
cluster_admin_principal_arns = []

# ------------------------------------------------------------------------------
# DNS and TLS
# ------------------------------------------------------------------------------

domain_name = "thirucloud.shop"
subdomain   = "eventhub"

# dev created the hosted zone; prod reuses it.
create_route53_zone = false

acme_email = "tirucloud@gmail.com"

use_letsencrypt_staging = false

# On from the start: by the time these environments are built, dev has already
# proved the delegation and issuance path works.
enable_tls                     = true
traefik_redirect_http_to_https = true

# ------------------------------------------------------------------------------
# Application
# ------------------------------------------------------------------------------

app_namespace = "eventhub"

# Never "latest" in production. A pod restarted at 3am must come back on exactly
# the code its siblings are running, and "latest" cannot promise that. Set this
# to the SHA that passed stage.
#
#     image_tag = "3f9a1c2e8b7d6f5a4c3b2a1908f7e6d5c4b3a291"
image_tag = "latest"

# With an immutable SHA tag there is nothing to re-pull, so avoid the registry
# round trip on every pod start.
image_pull_policy = "IfNotPresent"

app_replicas     = 3
enable_hpa       = true
hpa_min_replicas = 3
hpa_max_replicas = 12

log_level = "info"

# Never anything but zero here. This deliberately breaks payments.
payment_failure_rate_percent = 0

postgres_storage_size = "50Gi"

# ------------------------------------------------------------------------------
# Registry
# ------------------------------------------------------------------------------

# Refuse to delete a repository that still contains images. In prod, `terraform
# destroy` should be inconvenient.
ecr_force_delete   = false
images_per_service = 30

# ------------------------------------------------------------------------------
# Helm chart versions
#
# Pin every one of these in production. "Latest at apply time" means a routine
# apply can silently upgrade your ingress controller.
# ------------------------------------------------------------------------------

aws_load_balancer_controller_chart_version = "3.5.0"
cluster_autoscaler_chart_version           = "9.59.0"
cert_manager_chart_version                 = "v1.21.1"
traefik_chart_version                      = "41.2.0"

traefik_replicas = 3

# ------------------------------------------------------------------------------
# GitHub Actions credentials
# ------------------------------------------------------------------------------

enable_github_oidc          = false
github_oidc_create_provider = false
github_owner                = "vijaygiduthuri"
github_repository           = "EventHub-Terraform-EKS"
