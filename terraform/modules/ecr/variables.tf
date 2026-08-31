variable "repository_name" {
  description = "Name of the single ECR repository holding all service images."
  type        = string
}

variable "services" {
  description = "Service names used as tag prefixes. Each gets its own lifecycle rule."
  type        = list(string)

  validation {
    condition     = length(var.services) > 0 && length(var.services) <= 99
    error_message = "Provide between 1 and 99 services; rule priorities 1-99 are reserved for them."
  }
}

variable "image_tag_mutability" {
  description = "MUTABLE or IMMUTABLE. Must be MUTABLE for the <service>-latest tags this pipeline pushes."
  type        = string
  default     = "MUTABLE"

  validation {
    condition     = contains(["MUTABLE", "IMMUTABLE"], var.image_tag_mutability)
    error_message = "image_tag_mutability must be MUTABLE or IMMUTABLE."
  }
}

variable "scan_on_push" {
  description = "Run ECR basic scanning when an image is pushed."
  type        = bool
  default     = true
}

variable "images_per_service" {
  description = "How many tagged images to keep per service before the oldest are expired."
  type        = number
  default     = 15

  validation {
    condition     = var.images_per_service >= 3
    error_message = "Keep at least 3 images per service so a rollback target always exists."
  }
}

variable "untagged_retention_days" {
  description = "Days before untagged images are expired."
  type        = number
  default     = 1
}

variable "force_delete" {
  description = "Allow `terraform destroy` to delete the repository while it still contains images. Convenient for a workshop, dangerous in production."
  type        = bool
  default     = true
}

variable "cross_account_pull_arns" {
  description = "IAM principal ARNs from other accounts allowed to pull images. Empty means same-account access only."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to the repository."
  type        = map(string)
  default     = {}
}
