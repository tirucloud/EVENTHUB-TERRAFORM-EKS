variable "namespace" {
  description = "Namespace cert-manager is installed into. Must match the namespace in its IRSA role trust policy."
  type        = string
  default     = "cert-manager"
}

variable "service_account_name" {
  description = "Service account cert-manager runs as. Must match the name in its IRSA role trust policy."
  type        = string
  default     = "cert-manager"
}

variable "chart_version" {
  description = "cert-manager Helm chart version. Null means latest at apply time; pin it before running this in front of an audience."
  type        = string
  default     = null
}

variable "irsa_role_arn" {
  description = "IRSA role granting Route53 access for the DNS-01 solver. Null installs cert-manager without AWS permissions, which only works for HTTP-01."
  type        = string
  default     = null
}

variable "acme_email" {
  description = "Address registered with the ACME account. Let's Encrypt sends expiry warnings here, and registration fails without a valid one."
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.acme_email))
    error_message = "acme_email must be a valid email address."
  }
}

variable "aws_region" {
  description = "Region passed to the Route53 solver."
  type        = string
}

variable "dns_zone_id" {
  description = "Hosted zone the DNS-01 solver writes _acme-challenge records into."
  type        = string
}

variable "dns_zone_name" {
  description = "Apex domain, used as the issuer's zone selector so it only attempts challenges for names it owns."
  type        = string
}
