variable "cluster_name" {
  description = "Cluster the add-ons and controllers are installed into."
  type        = string
}

variable "kubernetes_version" {
  description = "Control plane version, used to resolve the recommended managed add-on versions."
  type        = string
}

variable "aws_region" {
  description = "Region the cluster runs in. Passed to the controllers."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster runs in. The load balancer controller needs it for subnet discovery."
  type        = string
}

# ------------------------------------------------------------------------------
# Managed add-ons
# ------------------------------------------------------------------------------

variable "ebs_csi_driver_role_arn" {
  description = "IRSA role for the EBS CSI driver. Without it the driver cannot create volumes and every PVC stays Pending."
  type        = string
}

variable "enable_metrics_server" {
  description = <<-EOT
    Install metrics-server as a managed add-on.

    Set false if your region's add-on catalogue does not offer it yet and
    install the Helm chart separately. Either way, a HorizontalPodAutoscaler
    needs it — without metrics-server an HPA sits at <unknown>/70% forever.
  EOT
  type        = bool
  default     = true
}

variable "enable_pod_identity_agent" {
  description = "Install the EKS Pod Identity agent alongside IRSA. Not used by EventHub, which uses IRSA throughout."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Helm-based controllers
# ------------------------------------------------------------------------------

variable "enable_aws_load_balancer_controller" {
  description = "Install the AWS Load Balancer Controller. Required for the Traefik Service to get a Network Load Balancer."
  type        = bool
  default     = true
}

variable "aws_load_balancer_controller_role_arn" {
  description = "IRSA role for the AWS Load Balancer Controller."
  type        = string
  default     = null
}

variable "aws_load_balancer_controller_chart_version" {
  description = "Chart version. Null means latest at apply time; pin it before a live session."
  type        = string
  default     = null
}

variable "enable_cluster_autoscaler" {
  description = "Install Cluster Autoscaler so the node group grows and shrinks with demand."
  type        = bool
  default     = true
}

variable "cluster_autoscaler_role_arn" {
  description = "IRSA role for Cluster Autoscaler."
  type        = string
  default     = null
}

variable "cluster_autoscaler_chart_version" {
  description = "Chart version. Null means latest at apply time; pin it before a live session."
  type        = string
  default     = null
}

variable "scale_down_unneeded_time" {
  description = "How long a node must look unneeded before Cluster Autoscaler removes it."
  type        = string
  default     = "5m"
}

variable "scale_down_delay_after_add" {
  description = "Grace period after a scale-up before any scale-down is considered."
  type        = string
  default     = "5m"
}

variable "tags" {
  description = "Tags applied to the managed add-ons."
  type        = map(string)
  default     = {}
}
