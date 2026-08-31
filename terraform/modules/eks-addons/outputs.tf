output "installed_addons" {
  description = "Managed add-on name to the version installed."
  value = {
    for name, addon in aws_eks_addon.this :
    name => addon.addon_version
  }
}

output "aws_load_balancer_controller_installed" {
  description = "Whether the load balancer controller was installed. Traefik cannot get an NLB without it."
  value       = var.enable_aws_load_balancer_controller
}

output "cluster_autoscaler_installed" {
  description = "Whether Cluster Autoscaler was installed."
  value       = var.enable_cluster_autoscaler
}
