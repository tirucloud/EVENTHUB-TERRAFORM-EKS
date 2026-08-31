variable "name" {
  description = "Name prefix for every resource in this module."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name. Used for the kubernetes.io/cluster/<name> subnet tags that load balancer controllers rely on for subnet discovery."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC. A /16 leaves room for large private subnets, which matters because the VPC CNI gives every pod a real VPC IP address."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr)) && tonumber(split("/", var.vpc_cidr)[1]) <= 18
    error_message = "vpc_cidr must be a valid CIDR of /18 or larger; smaller blocks run out of pod IP addresses quickly."
  }
}

variable "availability_zone_count" {
  description = "How many availability zones to spread subnets across."
  type        = number
  default     = 3

  validation {
    condition     = var.availability_zone_count >= 2 && var.availability_zone_count <= 4
    error_message = "EKS requires subnets in at least 2 availability zones; more than 4 is unnecessary here."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use one shared NAT gateway instead of one per availability zone.

    true  — roughly $33/month, but the NAT is a single point of failure and all
            cross-AZ egress is billed as inter-AZ traffic. Right for a workshop.
    false — one NAT per AZ (~$33/month each). Right for production.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Send VPC flow logs to CloudWatch. Useful for debugging security group rules, but it is not free."
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention for the flow log group."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
