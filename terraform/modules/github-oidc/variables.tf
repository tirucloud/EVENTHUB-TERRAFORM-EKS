variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repository" {
  description = "Repository name, without the owner prefix."
  type        = string
}

variable "allowed_refs" {
  description = <<-EOT
    Subject suffixes permitted to assume the role. Empty allows any ref in the
    repository. To restrict to the main branch only:

      ["ref:refs/heads/main"]
  EOT
  type        = list(string)
  default     = []
}

variable "role_name" {
  description = "Name of the IAM role GitHub Actions assumes."
  type        = string
  default     = "eventhub-github-actions"
}

variable "ecr_repository_arn" {
  description = "ARN of the ECR repository the pipeline may push to."
  type        = string
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Set to false if the account already has one — an account may only have a single provider per issuer URL."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
