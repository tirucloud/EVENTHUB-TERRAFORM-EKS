variable "namespace" {
  description = "Namespace Traefik is installed into."
  type        = string
  default     = "traefik"
}

variable "chart_version" {
  description = <<-EOT
    Traefik Helm chart version. Null means whatever is latest at apply time.

    Convenient while building this out and a hazard on the day of a session: a
    chart released that morning can rename a values key and break the apply.
    Run `helm search repo traefik/traefik` and pin the version you tested.
  EOT
  type        = string
  default     = null
}

variable "replicas" {
  description = "Traefik pod count. Two is the minimum that survives a node going away."
  type        = number
  default     = 2
}

variable "internal" {
  description = "Create an internal load balancer instead of an internet-facing one."
  type        = bool
  default     = false
}

variable "load_balancer_security_group_id" {
  description = "Security group to attach to the NLB. Null lets the AWS Load Balancer Controller manage its own."
  type        = string
  default     = null
}

variable "service_annotations" {
  description = "Extra annotations merged onto the Traefik Service, for load balancer settings this module does not expose."
  type        = map(string)
  default     = {}
}

variable "set_as_default_ingress_class" {
  description = "Make Traefik the default IngressClass, so an Ingress without ingressClassName still routes."
  type        = bool
  default     = true
}

variable "redirect_http_to_https" {
  description = "Permanently redirect port 80 to 443 at the Traefik entrypoint."
  type        = bool
  default     = true
}

variable "https_public_port" {
  description = <<-EOT
    The port the world reaches HTTPS on, used to build the HTTP-to-HTTPS
    redirect target.

    Traefik listens on 8443 inside the container and never sees the Service's
    443 -> 8443 mapping, so without this it would redirect users to
    https://your-domain:8443/ — a port the load balancer does not listen on.
  EOT
  type        = number
  default     = 443
}

variable "additional_arguments" {
  description = "Extra Traefik CLI arguments appended to the ones this module sets."
  type        = list(string)
  default     = []
}

variable "log_level" {
  description = "Traefik log level: DEBUG, INFO, WARN or ERROR."
  type        = string
  default     = "INFO"

  validation {
    condition     = contains(["DEBUG", "INFO", "WARN", "ERROR"], var.log_level)
    error_message = "log_level must be one of DEBUG, INFO, WARN, ERROR."
  }
}

variable "enable_access_logs" {
  description = "Log every request Traefik handles. Useful in a demo, noisy at volume."
  type        = bool
  default     = true
}

variable "resources" {
  description = "Requests and limits for the Traefik container."
  type = object({
    cpu_request    = string
    memory_request = string
    memory_limit   = string
  })
  default = {
    cpu_request    = "100m"
    memory_request = "128Mi"
    memory_limit   = "256Mi"
  }
}

variable "timeout_seconds" {
  description = "How long to wait for the Helm release, including the load balancer becoming active."
  type        = number
  default     = 900
}

# ------------------------------------------------------------------------------
# DNS
# ------------------------------------------------------------------------------

variable "cluster_name" {
  description = "EKS cluster name. Used to find the load balancer the AWS Load Balancer Controller created, via its elbv2.k8s.aws/cluster tag."
  type        = string
}

variable "dns_zone_id" {
  description = "Route53 hosted zone to publish records into."
  type        = string
}

variable "hostnames" {
  description = <<-EOT
    Fully qualified names to point at the load balancer.

    These become Route53 ALIAS records, so the **zone apex works** —
    ["thirucloud.shop"] is valid, which a CNAME could never be. Subdomains
    work through the same mechanism. Empty creates no records.
  EOT
  type        = list(string)
  default     = []
}

# ALIAS records take no TTL — Route53 follows the target's own TTL — so there is
# deliberately no dns_record_ttl variable.
