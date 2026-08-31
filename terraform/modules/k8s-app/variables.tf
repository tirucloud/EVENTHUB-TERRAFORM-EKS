# ------------------------------------------------------------------------------
# Placement
# ------------------------------------------------------------------------------

variable "namespace" {
  description = "Namespace all five services and their database run in."
  type        = string
  default     = "eventhub"
}

variable "environment" {
  description = "Environment name, applied as a label and surfaced in the UI."
  type        = string
}

# ------------------------------------------------------------------------------
# Images
# ------------------------------------------------------------------------------

variable "ecr_repository_url" {
  description = "ECR repository holding all five images, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/eventhub."
  type        = string
}

variable "image_tag" {
  description = <<-EOT
    Tag suffix each service runs, appended to the service name.

    "latest" resolves to <repo>:<service>-latest, which is what the pipeline
    keeps current. Set this to a commit SHA for anything you care about —
    "latest" is a moving target, so a pod restarted overnight can quietly come
    back on different code than its siblings.
  EOT
  type        = string
  default     = "latest"
}

variable "image_pull_policy" {
  description = "IfNotPresent avoids a registry round trip on every pod start. Always is right while iterating on the mutable -latest tag."
  type        = string
  default     = "IfNotPresent"

  validation {
    condition     = contains(["Always", "IfNotPresent", "Never"], var.image_pull_policy)
    error_message = "image_pull_policy must be Always, IfNotPresent or Never."
  }
}

# ------------------------------------------------------------------------------
# Scaling
# ------------------------------------------------------------------------------

variable "replicas" {
  description = "Starting replica count per service. The HPA takes ownership once it is running."
  type        = number
  default     = 2
}

variable "enable_hpa" {
  description = "Create HorizontalPodAutoscalers. Requires metrics-server, installed by the eks-addons module."
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
  description = "Average CPU utilisation, as a percentage of the request, the HPA scales to maintain."
  type        = number
  default     = 70
}

# ------------------------------------------------------------------------------
# Ingress and TLS
# ------------------------------------------------------------------------------

variable "app_fqdn" {
  description = "Hostname the application is served from, e.g. eventhub.thirucloud.shop."
  type        = string
}

variable "ingress_class_name" {
  description = "IngressClass that should serve these Ingresses. Comes from the traefik module."
  type        = string
  default     = "traefik"
}

variable "tls_secret_name" {
  description = "Secret cert-manager writes the issued certificate into, and that Traefik reads it from."
  type        = string
  default     = "eventhub-tls"
}

variable "cluster_issuer" {
  description = <<-EOT
    ClusterIssuer that signs the certificate.

    Use letsencrypt-staging until you have watched a certificate reach
    Ready=True. Staging certificates are untrusted so browsers warn, but the
    rate limits are effectively unlimited — production allows only 5 duplicate
    certificates per domain per week, which is easy to exhaust while debugging
    DNS delegation.
  EOT
  type        = string
  default     = "letsencrypt-staging"
}

variable "enable_tls" {
  description = "Request a certificate and serve HTTPS. Set false to run plain HTTP against the load balancer hostname before DNS is delegated."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Application behaviour
# ------------------------------------------------------------------------------

variable "log_level" {
  description = "Log level for all five services: debug, info, warn or error."
  type        = string
  default     = "info"
}

variable "payment_failure_rate_percent" {
  description = "Percentage of payments the mock gateway declines at random. Raise it to demonstrate the booking saga compensating under load."
  type        = number
  default     = 0

  validation {
    condition     = var.payment_failure_rate_percent >= 0 && var.payment_failure_rate_percent <= 100
    error_message = "payment_failure_rate_percent must be between 0 and 100."
  }
}

# ------------------------------------------------------------------------------
# Database
# ------------------------------------------------------------------------------

variable "postgres_image" {
  description = "PostgreSQL image for the StatefulSet."
  type        = string
  default     = "postgres:16-alpine"
}

variable "postgres_storage_size" {
  description = "Size of the EBS volume backing PostgreSQL."
  type        = string
  default     = "10Gi"
}

variable "storage_class_name" {
  description = "StorageClass for the database volume. This module creates a gp3 class of this name."
  type        = string
  default     = "gp3"
}

variable "postgres_resources" {
  description = "Requests and limits for the PostgreSQL container."
  type = object({
    cpu_request    = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    cpu_request    = "100m"
    memory_request = "256Mi"
    memory_limit   = "512Mi"
  }
}

variable "enforce_pod_security_restricted" {
  description = "Apply the restricted Pod Security Standard to the namespace. Every workload here already complies."
  type        = bool
  default     = true
}
