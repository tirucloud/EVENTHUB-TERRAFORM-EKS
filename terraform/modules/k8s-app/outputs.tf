output "namespace" {
  description = "Namespace the application runs in."
  value       = kubernetes_namespace_v1.eventhub.metadata[0].name
}

output "app_url" {
  description = "Public URL, once DNS is delegated and the certificate has issued."
  value       = "${var.enable_tls ? "https" : "http"}://${var.app_fqdn}"
}

output "images" {
  description = "Image each service is running."
  value       = local.image
}

output "service_urls" {
  description = "In-cluster URLs the services use to reach each other."
  value       = local.url
}

output "storage_class_name" {
  description = "StorageClass created for the database volume."
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}

output "tls_secret_name" {
  description = "Secret cert-manager writes the certificate into."
  value       = var.tls_secret_name
}

output "cluster_issuer" {
  description = "ClusterIssuer requested by the frontend Ingress."
  value       = var.enable_tls ? var.cluster_issuer : null
}

output "postgres_password_command" {
  description = "Reads the generated PostgreSQL password back out of the cluster."
  value       = "kubectl -n ${var.namespace} get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d"
}
