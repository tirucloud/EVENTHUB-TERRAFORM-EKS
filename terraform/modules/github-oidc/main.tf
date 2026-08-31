# GitHub Actions OIDC federation.
#
# The alternative to the AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY pair the
# build-scan-push workflow uses today. GitHub mints a short-lived token for each
# workflow run, AWS trusts GitHub as an identity provider, and the run exchanges
# that token for temporary credentials. Nothing long-lived exists in the
# repository, so nothing can leak from it or need rotating.
#
# This module is off by default (enable_github_oidc = false in 01-infra) because
# the project was asked for static keys. Flip it on, follow the instructions in
# the output, and delete both repository secrets.

locals {
  # Restricts the role to this repository — and optionally to specific branches
  # or tags. "repo:owner/name:*" allows any ref; narrowing it to
  # "repo:owner/name:ref:refs/heads/main" means a pull request branch cannot
  # assume the role even if someone pushes a workflow change.
  subjects = length(var.allowed_refs) > 0 ? [
    for ref in var.allowed_refs : "repo:${var.github_owner}/${var.github_repository}:${ref}"
  ] : ["repo:${var.github_owner}/${var.github_repository}:*"]
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  # AWS validates GitHub's certificate chain itself for this well-known issuer,
  # so the thumbprint no longer needs to be kept current by hand.
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = var.tags
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike rather than StringEquals so a "*" wildcard in the subject works.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = var.role_name
  description        = "Assumed by GitHub Actions to push EventHub images to ECR"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, { Name = var.role_name })
}

# Exactly the permissions the pipeline needs: authenticate to the registry, and
# push to the one EventHub repository. No read access to any other repository,
# no ability to delete images.
data "aws_iam_policy_document" "ecr_push" {
  statement {
    sid       = "GetAuthorizationToken"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushToEventHubRepository"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_policy" "ecr_push" {
  name        = "${var.role_name}-ecr-push"
  description = "Push access to the EventHub ECR repository"
  policy      = data.aws_iam_policy_document.ecr_push.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ecr_push" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.ecr_push.arn
}
