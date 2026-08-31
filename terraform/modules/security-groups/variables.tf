variable "name" {
  description = "Name prefix for the security groups."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR, used for the in-VPC access rules."
  type        = string
}

variable "ingress_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the public load balancer on 80 and 443.

    Defaults to the whole internet because EventHub is a public site. For a
    private demo, narrow this to your office or home address.
  EOT
  type        = list(string)
  default     = ["0.0.0.0/0"]

  validation {
    condition     = length(var.ingress_cidrs) > 0
    error_message = "At least one CIDR must be allowed, otherwise nothing can reach the application."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
