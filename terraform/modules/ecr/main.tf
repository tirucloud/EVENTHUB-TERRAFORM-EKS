# A single ECR repository holding the images for all five services.
#
# One repository means images are told apart by tag prefix:
#
#   eventhub:event-service-latest
#   eventhub:event-service-3f9a1c2...
#   eventhub:booking-service-latest
#
# Worth being explicit about the trade-off during the session: one repository is
# simpler to create and grant access to, but scan settings, tag immutability and
# lifecycle rules are then shared by all five services, and IAM cannot grant
# push access to one service without granting it to all of them. A repository
# per service is the usual production choice.

resource "aws_ecr_repository" "this" {
  name = var.repository_name

  # MUTABLE is required by the <service>-latest tags the pipeline pushes.
  # IMMUTABLE would reject the second push of any tag, which is the safer
  # setting when every deployment references an immutable digest or SHA tag.
  image_tag_mutability = var.image_tag_mutability

  force_delete = var.force_delete

  image_scanning_configuration {
    # Basic scanning at push time. This is AWS-side and independent of the
    # Trivy gate in CI: Trivy blocks a bad image from ever being pushed, while
    # this keeps finding new CVEs in images that were already clean when pushed.
    scan_on_push = var.scan_on_push
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(var.tags, { Name = var.repository_name })
}

locals {
  # One rule per service keeps the newest N images of that service and expires
  # the rest. Rules are evaluated in priority order, lowest number first.
  service_rules = [
    for index, service in var.services : {
      rulePriority = index + 1
      description  = "Keep the newest ${var.images_per_service} ${service} images"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["${service}-"]
        countType     = "imageCountMoreThan"
        countNumber   = var.images_per_service
      }
      action = { type = "expire" }
    }
  ]

  # Untagged images are layers left behind when a tag moves to a new push. They
  # are pure storage cost with no way to reference them.
  untagged_rule = {
    rulePriority = 100
    description  = "Expire untagged images after ${var.untagged_retention_days} day(s)"
    selection = {
      tagStatus   = "untagged"
      countType   = "sinceImagePushed"
      countUnit   = "days"
      countNumber = var.untagged_retention_days
    }
    action = { type = "expire" }
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    rules = concat(local.service_rules, [local.untagged_rule])
  })
}

# Optional: let other AWS accounts pull these images. Left empty by default,
# since the EKS nodes in this account get pull access from the
# AmazonEC2ContainerRegistryReadOnly policy on their instance role.
resource "aws_ecr_repository_policy" "cross_account_pull" {
  count = length(var.cross_account_pull_arns) > 0 ? 1 : 0

  repository = aws_ecr_repository.this.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCrossAccountPull"
      Effect    = "Allow"
      Principal = { AWS = var.cross_account_pull_arns }
      Action = [
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}
