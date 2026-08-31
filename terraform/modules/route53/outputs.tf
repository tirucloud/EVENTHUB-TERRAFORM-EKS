output "zone_id" {
  description = "Hosted zone ID. ExternalDNS and cert-manager both need scoped write access to it."
  value       = local.zone_id
}

output "zone_arn" {
  description = "Hosted zone ARN, used to scope the ExternalDNS and cert-manager IAM policies to this zone alone."
  value       = "arn:aws:route53:::hostedzone/${local.zone_id}"
}

output "name_servers" {
  description = "Set these four nameservers at your registrar. Until you do, nothing in this zone resolves publicly."
  value       = local.name_servers
}

output "domain_name" {
  description = "The apex domain."
  value       = var.domain_name
}

output "app_fqdn" {
  description = "Fully qualified hostname EventHub is served from."
  value       = local.app_fqdn
}

output "delegation_instructions" {
  description = "What to do at GoDaddy once the infrastructure exists."
  value       = <<-EOT
    Point ${var.domain_name} at this Route53 hosted zone.

    GoDaddy: My Products -> ${var.domain_name} -> DNS -> Nameservers ->
    Change -> "I'll use my own nameservers", then enter:

    ${join("\n    ", local.name_servers)}

    Enter the names exactly as shown; GoDaddy rejects a trailing dot.

    Check that delegation has propagated:
        dig +short NS ${var.domain_name} @8.8.8.8

    Once that returns the four names above, two things happen on their own:
      - ExternalDNS publishes ${local.app_fqdn} pointing at the Traefik NLB
      - cert-manager completes the DNS-01 challenge and Let's Encrypt issues
        the certificate

    Neither needs another terraform apply. Watch progress with:
        kubectl get certificate -A -w
  EOT
}
