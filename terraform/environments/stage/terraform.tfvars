# ==============================================================================
# stage — production's shape, at a smaller size
#
# The point of stage is that a change which works here will work in prod. So it
# keeps prod's settings wherever they affect behaviour (real certificates,
# pinned images, info-level logs) and only shrinks the things that cost money.
# ==============================================================================

aws_region  = "us-east-1"
project     = "eventhub"
environment = "stage"

# ------------------------------------------------------------------------------
# Network
#
# A distinct CIDR from dev and prod. They do not talk to each other today, but
# overlapping ranges make peering or a transit gateway impossible later, and
# renumbering a live VPC means rebuilding it.
# ------------------------------------------------------------------------------

vpc_cidr                = "10.1.0.0/16"
availability_zone_count = 3

# Still one NAT gateway. Stage does not need to survive an AZ outage, and this
# saves about $66/month.
single_nat_gateway = true
enable_flow_logs   = false

# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

kubernetes_version  = "1.35"
node_instance_types = ["t3.large"]
node_capacity_type  = "ON_DEMAND"
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 6
node_disk_size      = 30

endpoint_public_access = true
public_access_cidrs    = ["0.0.0.0/0"]

cluster_admin_principal_arns = []

# ------------------------------------------------------------------------------
# DNS and TLS
# ------------------------------------------------------------------------------

domain_name = "thirucloud.shop"
subdomain   = "eventhub-stage"

# dev created the hosted zone; stage reuses it.
create_route53_zone = false

acme_email = "tirucloud@gmail.com"

# Real certificates, because stage exists to catch problems before prod — and a
# certificate that only works against staging is exactly such a problem.
use_letsencrypt_staging = false

# On from the start: by the time these environments are built, dev has already
# proved the delegation and issuance path works.
enable_tls                     = true
traefik_redirect_http_to_https = true

# ------------------------------------------------------------------------------
# Application
# ------------------------------------------------------------------------------

app_namespace = "eventhub"

# Pin this to the commit SHA you are promoting. Stage tracking "latest" would
# defeat its purpose: you could not tell which build you had just approved.
image_tag         = "latest"
image_pull_policy = "IfNotPresent"

app_replicas     = 2
enable_hpa       = true
hpa_min_replicas = 2
hpa_max_replicas = 8

log_level = "info"

payment_failure_rate_percent = 0

postgres_storage_size = "20Gi"

# ------------------------------------------------------------------------------
# Helm chart versions — pin these to whatever dev proved out
# ------------------------------------------------------------------------------

aws_load_balancer_controller_chart_version = "3.5.0"
cluster_autoscaler_chart_version           = "9.59.0"
cert_manager_chart_version                 = "v1.21.1"
traefik_chart_version                      = "41.2.0"

# ------------------------------------------------------------------------------
# GitHub Actions credentials
#
# The account-wide OIDC provider is created by dev, so stage must not try to
# create a second one.
# ------------------------------------------------------------------------------

enable_github_oidc          = false
github_oidc_create_provider = false
github_owner                = "vijaygiduthuri"
github_repository           = "EventHub-Terraform-EKS"
