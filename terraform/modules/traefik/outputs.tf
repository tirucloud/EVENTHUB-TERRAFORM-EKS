output "namespace" {
  description = "Namespace Traefik runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "ingress_class_name" {
  description = "IngressClass name to put on every Ingress that Traefik should serve."
  value       = "traefik"
}

output "load_balancer_hostname" {
  description = "DNS name of the NLB. Reachable before any Route53 record exists, which makes it the quickest way to test the cluster in isolation."
  value       = local.load_balancer_hostname
}

output "hostnames" {
  description = "Names published into Route53 for this load balancer."
  value       = [for record in aws_route53_record.app : record.fqdn]
}

output "curl_check" {
  description = "Tests the cluster end to end while bypassing DNS entirely. Traefik routes on Host, so the header is required."
  value = local.load_balancer_hostname == "" ? "load balancer not provisioned yet" : format(
    "curl -H 'Host: %s' http://%s/api/events",
    try(var.hostnames[0], "example.com"),
    local.load_balancer_hostname,
  )
}
