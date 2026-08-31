# ==============================================================================
# dev — small, cheap, and the environment that creates the shared hosted zone
# ==============================================================================

aws_region  = "us-east-1"
project     = "eventhub"
environment = "dev"

# ------------------------------------------------------------------------------
# Network — one NAT gateway, because dev does not need three
# ------------------------------------------------------------------------------

vpc_cidr                = "10.0.0.0/16"
availability_zone_count = 3
single_nat_gateway      = true
enable_flow_logs        = false

# ------------------------------------------------------------------------------
# Cluster — the smallest thing that comfortably runs EventHub
#
# t3.large is about pod density, not CPU. The VPC CNI gives every pod a real
# VPC address from the node's ENIs, and that count is fixed per instance type:
# t3.medium allows 17 pods, t3.large 35. EventHub plus its controllers is around
# 25 pods, so t3.medium would leave no headroom and the first scale-up would
# fail with pods stuck Pending on "too many pods".
# ------------------------------------------------------------------------------

kubernetes_version  = "1.35"
node_instance_types = ["t3.large"]
node_capacity_type  = "ON_DEMAND"
node_desired_size   = 2
node_min_size       = 2
node_max_size       = 5
node_disk_size      = 30

# Convenient for a workshop. Narrow to your own address for anything longer:
#     public_access_cidrs = ["203.0.113.45/32"]
endpoint_public_access = true
public_access_cidrs    = ["0.0.0.0/0"]

cluster_admin_principal_arns = []

# ------------------------------------------------------------------------------
# DNS — dev creates the zone the other environments reuse
# ------------------------------------------------------------------------------

domain_name = "thirucloud.shop"

# Empty means serve from the zone apex: https://thirucloud.shop
#
# Only possible because the traefik module publishes Route53 ALIAS records — a
# CNAME cannot legally exist at a zone apex alongside the mandatory SOA and NS
# records.
#
# Only ONE environment can own the apex. stage and prod therefore keep
# subdomains.
subdomain = ""

# Exactly one environment must create the hosted zone. dev builds first, so it
# owns it; stage and prod look it up.
create_route53_zone = true

acme_email = "tirucloud@gmail.com"

# These three are the ONLY values you change while following docs/aws, and all
# three change in Phase 5. They ship in their Phase-1 starting state.
#
# Both flags start false because the application has to be reachable over plain
# HTTP through the load balancer hostname before the domain is delegated.
# Turning on the redirect early sends every request to an HTTPS URL that does
# not resolve yet; turning on TLS early puts an Ingress in front of a
# certificate nothing can issue.
enable_tls                     = false
traefik_redirect_http_to_https = false

# Phase 5 sets both to true, then flips this to false once a staging
# certificate has been seen to issue. Staging certificates are untrusted so
# browsers warn, but the rate limits are effectively unlimited — production
# allows only 5 duplicate certificates per domain per week, which is easy to
# exhaust while debugging DNS.
use_letsencrypt_staging = true

# ------------------------------------------------------------------------------
# Application
# ------------------------------------------------------------------------------

app_namespace = "eventhub"

# "latest" is what the pipeline keeps current. Pin to a commit SHA when you want
# every pod on identical code.
image_tag = "latest"

# Always, because dev tracks the mutable -latest tag and a restarted pod should
# pick up a newly pushed image rather than reusing the cached one.
image_pull_policy = "Always"

app_replicas     = 2
enable_hpa       = true
hpa_min_replicas = 2
hpa_max_replicas = 6

log_level = "debug"

# Raise to demonstrate the booking saga compensating under load.
payment_failure_rate_percent = 0

postgres_storage_size = "10Gi"

# ------------------------------------------------------------------------------
# Helm chart versions
#
# null means "latest at apply time", which is fine while building this out and a
# hazard on the day of a session: a chart released that morning can rename a
# values key and break the apply in front of an audience.
#
# Run `helm search repo` for each and pin what you tested:
#
#   helm repo add traefik https://traefik.github.io/charts
#   helm repo add jetstack https://charts.jetstack.io
#   helm repo add eks https://aws.github.io/eks-charts
#   helm repo add autoscaler https://kubernetes.github.io/autoscaler
#   helm repo update && helm search repo traefik/traefik jetstack/cert-manager \
#     eks/aws-load-balancer-controller autoscaler/cluster-autoscaler
# ------------------------------------------------------------------------------

aws_load_balancer_controller_chart_version = "3.5.0"
cluster_autoscaler_chart_version           = "9.59.0"
cert_manager_chart_version                 = "v1.21.1"
traefik_chart_version                      = "41.2.0"

# ------------------------------------------------------------------------------
# GitHub Actions credentials
#
# The pipeline uses static access keys today. Set this true to create an OIDC
# role instead and drop both repository secrets. The OIDC provider is
# account-wide, so only one environment should create it.
# ------------------------------------------------------------------------------

enable_github_oidc          = false
github_oidc_create_provider = true
github_owner                = "tirucloud"
github_repository           = "EventHub-Terraform-EKS"
