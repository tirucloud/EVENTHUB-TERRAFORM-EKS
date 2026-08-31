output "role_arn" {
  description = "ARN of the role. Put this on the service account as the eks.amazonaws.com/role-arn annotation."
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "Name of the role."
  value       = aws_iam_role.this.name
}

output "service_account_subjects" {
  description = "The system:serviceaccount:<ns>:<name> subjects this role trusts. Handy when debugging an AccessDenied."
  value       = local.subjects
}
