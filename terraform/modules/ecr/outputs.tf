output "repository_name" {
  description = "Repository name."
  value       = aws_ecr_repository.this.name
}

output "repository_url" {
  description = "Repository URL, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/eventhub. Append :<service>-<tag> to reference an image."
  value       = aws_ecr_repository.this.repository_url
}

output "repository_arn" {
  description = "Repository ARN."
  value       = aws_ecr_repository.this.arn
}

output "registry_id" {
  description = "AWS account ID that owns the registry."
  value       = aws_ecr_repository.this.registry_id
}

output "image_uris" {
  description = "Convenience map of service name to its :<service>-latest image URI."
  value = {
    for service in var.services :
    service => "${aws_ecr_repository.this.repository_url}:${service}-latest"
  }
}
