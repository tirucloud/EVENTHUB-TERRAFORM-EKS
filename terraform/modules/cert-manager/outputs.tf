output "namespace" {
  description = "Namespace cert-manager runs in."
  value       = kubernetes_namespace_v1.this.metadata[0].name
}

output "staging_issuer_name" {
  description = "ClusterIssuer backed by Let's Encrypt staging. Untrusted by browsers, but effectively unlimited — use it until issuance works."
  value       = "letsencrypt-staging"
}

output "production_issuer_name" {
  description = "ClusterIssuer backed by Let's Encrypt production. Limited to 5 duplicate certificates per domain per week."
  value       = "letsencrypt-prod"
}

output "issuer_names" {
  description = "Both ClusterIssuers this module creates."
  value       = ["letsencrypt-staging", "letsencrypt-prod"]
}
