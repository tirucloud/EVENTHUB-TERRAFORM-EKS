# Public DNS zone for EventHub.
#
# This module deliberately does nothing but create the hosted zone and report
# its nameservers. Certificates are not issued here.
#
# TLS is handled inside the cluster by cert-manager and Let's Encrypt (see
# terraform/02-apps), which fits the delegation timeline much better than ACM
# would. ACM's DNS validation blocks `terraform apply` while it waits for the
# record to become visible in public DNS — so requesting a certificate before
# the GoDaddy nameservers are switched means Terraform hangs for the full
# validation timeout and then fails.
#
# cert-manager has no such problem: it runs as a controller, so it simply keeps
# retrying in the background. The order of operations becomes:
#
#   1. terraform apply 01-infra   → zone created, nameservers printed
#   2. terraform apply 02-apps    → cluster, Traefik and cert-manager deployed
#   3. update nameservers at GoDaddy
#   4. cert-manager notices DNS now resolves and issues the certificate on its
#      next retry, with no further Terraform runs
#
# ExternalDNS writes the A record for the application into this zone, and
# cert-manager writes the _acme-challenge TXT records into it for DNS-01
# validation. Both get scoped IAM access through IRSA in 01-infra.

resource "aws_route53_zone" "this" {
  count = var.create_zone ? 1 : 0

  name    = var.domain_name
  comment = "Public zone for ${var.domain_name}, managed by Terraform"

  # Deleting a hosted zone permanently changes its nameservers. Recreating it
  # later means going back to the registrar, so make it a deliberate act.
  force_destroy = var.zone_force_destroy

  tags = merge(var.tags, { Name = var.domain_name })
}

data "aws_route53_zone" "existing" {
  count = var.create_zone ? 0 : 1

  name         = var.domain_name
  private_zone = false
}

locals {
  zone_id      = var.create_zone ? aws_route53_zone.this[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name_servers = var.create_zone ? aws_route53_zone.this[0].name_servers : data.aws_route53_zone.existing[0].name_servers

  # An empty subdomain means serve from the zone apex itself.
  app_fqdn = var.subdomain == "" ? var.domain_name : "${var.subdomain}.${var.domain_name}"
}
