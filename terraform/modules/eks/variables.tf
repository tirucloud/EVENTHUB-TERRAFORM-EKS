variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the control plane, e.g. \"1.31\"."
  type        = string
  default     = "1.35"
}

variable "private_subnet_ids" {
  description = "Private subnets for the control plane ENIs and the worker nodes."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "EKS requires subnets in at least two availability zones."
  }
}

variable "additional_security_group_ids" {
  description = "Extra security groups attached to the control plane ENIs."
  type        = list(string)
  default     = []
}

variable "node_security_group_ids" {
  description = "Extra security groups attached to worker nodes through the launch template."
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "Expose the Kubernetes API endpoint publicly. Needed for kubectl from a laptop without a VPN or bastion."
  type        = bool
  default     = true
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public API endpoint. Narrow this to your own address for anything beyond a workshop."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enabled_log_types" {
  description = "Control plane log types shipped to CloudWatch."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]

  validation {
    condition = alltrue([
      for t in var.enabled_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)
    ])
    error_message = "Valid log types are api, audit, authenticator, controllerManager and scheduler."
  }
}

variable "log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 7
}

variable "enable_secrets_encryption" {
  description = "Encrypt Kubernetes Secrets in etcd with a dedicated KMS key."
  type        = bool
  default     = true
}

# ------------------------------------------------------------------------------
# Node group
# ------------------------------------------------------------------------------

variable "node_group_name" {
  description = "Short name for the managed node group."
  type        = string
  default     = "general"
}

variable "node_instance_types" {
  description = <<-EOT
    Instance types for the node group.

    t3.large (2 vCPU, 8 GiB) is the default because of pod density, not CPU.
    The VPC CNI gives every pod a real VPC IP from the node's ENIs, and the
    number of ENIs is fixed per instance type: t3.medium tops out at 17 pods,
    t3.large at 35. EventHub plus its addons is around 25 pods, so t3.medium
    would leave almost no headroom and the first scale-up would fail with pods
    stuck Pending on "too many pods".

    t3.medium works if you raise node_desired_size to 3, and saves about half.
    Listing several types improves capacity availability and is close to
    required when capacity_type is SPOT.
  EOT
  type        = list(string)
  default     = ["t3.large"]
}

variable "node_capacity_type" {
  description = "ON_DEMAND or SPOT. Spot is roughly 70% cheaper and fine for a workshop, but nodes can be reclaimed with two minutes' notice."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_capacity_type)
    error_message = "node_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_ami_type" {
  description = "EKS-managed AMI family. AL2023_x86_64_STANDARD is the current default for x86 nodes."
  type        = string
  default     = "AL2023_x86_64_STANDARD"
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB. Images, logs and the container runtime all live here."
  type        = number
  default     = 30
}

variable "node_desired_size" {
  description = "Starting node count. Cluster Autoscaler takes ownership of this value afterwards."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimum node count the autoscaler may scale down to."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximum node count the autoscaler may scale up to. This is the real ceiling on your bill."
  type        = number
  default     = 5
}

variable "node_labels" {
  description = "Extra Kubernetes labels applied to nodes."
  type        = map(string)
  default     = {}
}

variable "enable_detailed_monitoring" {
  description = "Enable EC2 detailed (1-minute) CloudWatch monitoring on nodes. Costs extra."
  type        = bool
  default     = false
}

# ------------------------------------------------------------------------------
# Access
# ------------------------------------------------------------------------------

variable "cluster_admin_principal_arns" {
  description = "IAM user or role ARNs granted cluster-admin through EKS access entries. The principal running the apply already has admin and does not need listing."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
