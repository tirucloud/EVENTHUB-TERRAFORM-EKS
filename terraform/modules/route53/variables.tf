variable "domain_name" {
  description = "Apex domain, e.g. thirucloud.shop."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "domain_name must be a bare domain in lowercase, with no scheme, port, trailing dot or path."
  }
}

variable "subdomain" {
  description = <<-EOT
    Subdomain EventHub is served from. "eventhub" gives
    eventhub.<domain_name>.

    Set to "" to serve from the **zone apex** (<domain_name> itself). That is
    only possible because the traefik module publishes Route53 ALIAS records —
    a CNAME is illegal at an apex.
  EOT
  type        = string
  default     = "eventhub"
}

variable "create_zone" {
  description = "Create the public hosted zone. Set to false to look up a zone that already exists in this account."
  type        = bool
  default     = true
}

variable "zone_force_destroy" {
  description = "Allow `terraform destroy` to delete the zone even when ExternalDNS and cert-manager have written records into it. Convenient for a workshop; it also means re-delegating at the registrar afterwards."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
