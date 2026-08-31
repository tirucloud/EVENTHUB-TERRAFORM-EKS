output "role_arn" {
  description = "Role ARN for the workflow's role-to-assume field."
  value       = aws_iam_role.github_actions.arn
}

output "workflow_snippet" {
  description = "Drop-in replacement for the static-credentials step in build-scan-push.yml."
  value       = <<-EOT
    Add to the workflow's top-level permissions block:

        id-token: write

    Then replace the "Configure AWS credentials" step with:

        - name: Configure AWS credentials
          uses: aws-actions/configure-aws-credentials@v4
          with:
            role-to-assume: ${aws_iam_role.github_actions.arn}
            aws-region: $${{ env.AWS_REGION }}

    Finally delete AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY from the
    repository secrets.
  EOT
}
