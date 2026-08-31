output "aws_region" {
  description = "Region this environment runs in."
  value       = var.aws_region
}

output "aws_account_id" {
  description = "Account this environment was applied to."
  value       = data.aws_caller_identity.current.account_id
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint."
  value       = module.eks.cluster_endpoint
}

output "kubeconfig_command" {
  description = "Point kubectl at this cluster."
  value       = module.eks.kubeconfig_command
}

output "vpc_id" {
  description = "VPC identifier."
  value       = module.vpc.vpc_id
}

output "nat_public_ips" {
  description = "Public IPs the cluster egresses from. Hand these to anyone who needs to allowlist your outbound traffic."
  value       = module.vpc.nat_public_ips
}

output "ecr_repository_url" {
  description = "ECR repository URL. Images are <url>:<service>-<tag>."
  value       = module.ecr.repository_url
}

output "image_uris" {
  description = "Per-service :<service>-latest image URIs."
  value       = module.ecr.image_uris
}

output "route53_name_servers" {
  description = "Nameservers to set at the registrar. Null when this environment did not create the zone."
  value       = var.create_route53_zone ? module.route53.name_servers : null
}

output "delegation_instructions" {
  description = "What to do at GoDaddy once the zone exists."
  value       = var.create_route53_zone ? module.route53.delegation_instructions : "This environment reuses an existing hosted zone; delegation was handled by whichever environment created it."
}

output "app_fqdn" {
  description = "Hostname this environment is served from."
  value       = local.app_fqdn
}

output "app_url" {
  description = "Public URL, once DNS is delegated and the certificate has issued."
  value       = "${var.enable_tls ? "https" : "http"}://${local.app_fqdn}"
}

output "load_balancer_hostname" {
  description = "NLB hostname. Reachable before any DNS record exists, which makes it the quickest way to test the cluster in isolation."
  value       = module.traefik.load_balancer_hostname
}

output "curl_check" {
  description = "Tests the whole stack while bypassing DNS. Traefik routes on Host, so the header is required."
  value       = module.traefik.curl_check
}

output "cluster_issuer" {
  description = "ClusterIssuer signing the certificate. Staging certificates are untrusted by design."
  value       = module.k8s_app.cluster_issuer
}

output "installed_addons" {
  description = "Managed add-on versions on the cluster."
  value       = module.eks_addons.installed_addons
}

output "postgres_password_command" {
  description = "Reads the generated database password out of the cluster."
  value       = module.k8s_app.postgres_password_command
}

output "github_actions_role_arn" {
  description = "OIDC role for GitHub Actions. Null unless enable_github_oidc is true."
  value       = var.enable_github_oidc ? module.github_oidc[0].role_arn : null
}
