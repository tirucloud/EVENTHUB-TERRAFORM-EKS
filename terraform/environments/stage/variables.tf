# ------------------------------------------------------------------------------
# Identity
# ------------------------------------------------------------------------------

variable "aws_region" {
  description = "Region for every resource in this environment. ap-south-1 (Mumbai) is closer from India and cuts round-trip latency noticeably."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Project name, used as a resource name prefix."
  type        = string
  default     = "eventhub"
}

variable "environment" {
  description = "Environment name. Also the resource name suffix, so it must be unique per environment in the account."
  type        = string
}

variable "services" {
  description = "The five service names. Used for ECR tag prefixes and lifecycle rules."
  type        = list(string)
  default = [
    "frontend-service",
    "event-service",
    "booking-service",
    "payment-service",
    "notification-service",
  ]
}

# ------------------------------------------------------------------------------
# Network
# ------------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Give each environment its own range if you ever intend to peer them."
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zone_count" {
  description = "Availability zones to spread subnets across."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "Share one NAT gateway across all private subnets. Saves roughly $66/month at three AZs, at the cost of a single point of failure."
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Ship VPC flow logs to CloudWatch."
  type        = bool
  default     = false
}

variable "allowed_lb_ingress_cidrs" {
  description = "CIDRs allowed to reach the public load balancer on 80 and 443."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# ------------------------------------------------------------------------------
# Cluster
# ------------------------------------------------------------------------------

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane."
  type        = string
  default     = "1.35"
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API publicly so kubectl works without a VPN or bastion."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Narrow to your own address for anything long-lived."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "node_instance_types" {
  description = "Instance types for the managed node group. Chosen for pod density as much as CPU: t3.medium allows 17 pods per node, t3.large 35."
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is roughly 70% cheaper and fine for non-production."
  type        = string
  default     = "ON_DEMAND"
}

variable "node_desired_size" {
  description = "Starting node count. Cluster Autoscaler owns this afterwards."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count. This is the real ceiling on the compute bill."
  type        = number
  default     = 5
}

variable "node_disk_size" {
  description = "Root EBS volume per node, in GiB."
  type        = number
  default     = 30
}

variable "cluster_admin_principal_arns" {
  description = "Extra IAM principals granted cluster-admin. Whoever runs the apply already has it."
  type        = list(string)
  default     = []
}

# ------------------------------------------------------------------------------
# Add-ons and controllers
# ------------------------------------------------------------------------------

variable "enable_metrics_server" {
  description = "Install metrics-server as a managed add-on. Required for HorizontalPodAutoscalers to function."
  type        = bool
  default     = true
}

variable "enable_cluster_autoscaler" {
  description = "Install Cluster Autoscaler."
  type        = bool
  default     = true
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Chart version. Null means latest at apply time; pin it before a live session."
  type        = string
  default     = null
}

variable "cluster_autoscaler_chart_version" {
  description = "Chart version. Null means latest at apply time."
  type        = string
  default     = null
}

variable "cert_manager_chart_version" {
  description = "Chart version. Null means latest at apply time."
  type        = string
  default     = null
}

variable "traefik_chart_version" {
  description = "Chart version. Null means latest at apply time."
  type        = string
  default     = null
}

variable "traefik_replicas" {
  description = "Traefik pod count."
  type        = number
  default     = 2
}

variable "traefik_redirect_http_to_https" {
  description = <<-EOT
    Permanently redirect port 80 to 443 at the Traefik entrypoint.

    Keep this false until TLS works. With the redirect on and no certificate
    yet, every plain HTTP request answers 308 pointing at an HTTPS URL that does
    not resolve — which makes the application impossible to reach through the
    load balancer hostname before DNS delegation. Turn it on together with
    enable_tls.
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Registry
# ------------------------------------------------------------------------------

variable "ecr_repository_name" {
  description = "Single ECR repository holding all five images. Shared across environments unless you change it."
  type        = string
  default     = "eventhub"
}

variable "images_per_service" {
  description = "Tagged images retained per service before the oldest expire."
  type        = number
  default     = 15
}

variable "ecr_force_delete" {
  description = "Let `terraform destroy` remove the repository while it still holds images."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# DNS and TLS
# ------------------------------------------------------------------------------

variable "domain_name" {
  description = "Apex domain."
  type        = string
  default     = "thirucloud.shop"
}

variable "subdomain" {
  description = "Subdomain this environment is served from, giving <subdomain>.<domain_name>."
  type        = string
}

variable "create_route53_zone" {
  description = "Create the hosted zone. Exactly one environment should do this; the others look the same zone up."
  type        = bool
  default     = false
}

variable "acme_email" {
  description = "Address registered with Let's Encrypt for expiry notices."
  type        = string
}

variable "use_letsencrypt_staging" {
  description = <<-EOT
    Issue from the Let's Encrypt staging environment.

    Leave true until you have watched a certificate reach Ready=True. Staging
    certificates are untrusted so browsers warn, but the rate limits are
    effectively unlimited. Production allows only 5 duplicate certificates per
    domain per week, which is easy to exhaust while debugging DNS delegation.
  EOT
  type        = bool
  default     = true
}

variable "enable_tls" {
  description = <<-EOT
    Serve HTTPS and request a certificate for the application Ingresses.

    False routes everything over the plain HTTP entrypoint, which is what makes
    the application testable through the load balancer hostname before the
    domain is delegated. Turned on in the same step as cert-manager.
  EOT
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Application
# ------------------------------------------------------------------------------

variable "app_namespace" {
  description = "Namespace the five services run in."
  type        = string
  default     = "eventhub"
}

variable "image_tag" {
  description = "Tag suffix each service runs. Pin to a commit SHA for anything you care about."
  type        = string
  default     = "latest"
}

variable "image_pull_policy" {
  description = "Always is right while iterating on the mutable -latest tag; IfNotPresent otherwise."
  type        = string
  default     = "IfNotPresent"
}

variable "app_replicas" {
  description = "Starting replica count per service."
  type        = number
  default     = 2
}

variable "enable_hpa" {
  description = "Create HorizontalPodAutoscalers."
  type        = bool
  default     = true
}

variable "hpa_min_replicas" {
  description = "Lower bound for every service's HPA."
  type        = number
  default     = 2
}

variable "hpa_max_replicas" {
  description = "Upper bound for every service's HPA."
  type        = number
  default     = 6
}

variable "hpa_cpu_target_percent" {
  description = "CPU utilisation the HPA scales to maintain, as a percentage of the request."
  type        = number
  default     = 70
}

variable "log_level" {
  description = "Log level for all five services."
  type        = string
  default     = "info"
}

variable "payment_failure_rate_percent" {
  description = "Percentage of payments the mock gateway declines at random. Raise it to demonstrate the booking saga compensating."
  type        = number
  default     = 0
}

variable "postgres_storage_size" {
  description = "EBS volume size for PostgreSQL."
  type        = string
  default     = "10Gi"
}

variable "postgres_image" {
  description = "PostgreSQL image."
  type        = string
  default     = "postgres:16-alpine"
}

# ------------------------------------------------------------------------------
# GitHub Actions OIDC (optional)
# ------------------------------------------------------------------------------

variable "enable_github_oidc" {
  description = "Create an OIDC role for GitHub Actions so the pipeline can drop its static access keys."
  type        = bool
  default     = false
}

variable "github_oidc_create_provider" {
  description = "Create the GitHub OIDC provider. An account may only have one, so exactly one environment should set this true."
  type        = bool
  default     = true
}

variable "github_owner" {
  description = "GitHub user or organisation owning the repository."
  type        = string
  default     = "vijaygiduthuri"
}

variable "github_repository" {
  description = "Repository name, without the owner prefix."
  type        = string
  default     = "EventHub-Terraform-EKS"
}
