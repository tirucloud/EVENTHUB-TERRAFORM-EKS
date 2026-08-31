variable "role_name" {
  description = "Name of the IAM role."
  type        = string
}

variable "description" {
  description = "Human-readable description shown in the IAM console."
  type        = string
  default     = "IAM role assumable by an EKS service account"
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster's IAM OIDC provider."
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC issuer URL with the https:// prefix stripped, e.g. oidc.eks.us-east-1.amazonaws.com/id/ABCDEF."
  type        = string

  validation {
    condition     = !startswith(var.oidc_provider_url, "https://")
    error_message = "Strip the https:// prefix; IAM condition keys are built from the bare host and path."
  }
}

variable "service_accounts" {
  description = "Service accounts permitted to assume this role."
  type = list(object({
    namespace = string
    name      = string
  }))

  validation {
    condition     = length(var.service_accounts) > 0
    error_message = "At least one service account must be allowed, otherwise nothing can assume the role."
  }
}

variable "policy_arns" {
  description = "ARNs of existing managed policies to attach."
  type        = list(string)
  default     = []
}

variable "inline_policy_json" {
  description = "Optional JSON policy document to create as a customer-managed policy and attach."
  type        = string
  default     = null
}

variable "max_session_duration" {
  description = "Maximum session length in seconds for credentials issued via this role."
  type        = number
  default     = 3600
}

variable "tags" {
  description = "Tags applied to the role."
  type        = map(string)
  default     = {}
}
