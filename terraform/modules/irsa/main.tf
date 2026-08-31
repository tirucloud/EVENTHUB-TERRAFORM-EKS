# IRSA: IAM Roles for Service Accounts.
#
# This is the mechanism that lets a pod call the AWS API without any static
# credentials. The chain is worth walking through slowly in the session, because
# every addon in this project depends on it:
#
#   1. The EKS cluster publishes an OIDC discovery document.
#   2. IAM trusts that issuer as an identity provider (created in the eks module).
#   3. The kubelet projects a signed JWT into the pod at
#      /var/run/secrets/eks.amazonaws.com/serviceaccount/token, with the pod's
#      ServiceAccount as the `sub` claim.
#   4. The AWS SDK inside the pod calls sts:AssumeRoleWithWebIdentity with that
#      token and gets temporary credentials back.
#
# The trust policy below is step 2's half of the contract: this role may only be
# assumed by a token whose `sub` claim names one of the listed service accounts.
# Get the namespace or name wrong and the pod gets AccessDenied — which is the
# single most common IRSA mistake.

locals {
  # e.g. "system:serviceaccount:kube-system:ebs-csi-controller-sa"
  subjects = [
    for sa in var.service_accounts :
    "system:serviceaccount:${sa.namespace}:${sa.name}"
  ]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    sid     = "AllowEKSServiceAccountToAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # Without the aud check, a token minted for a different audience could be
    # replayed against this role.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pins the role to specific service accounts.
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "this" {
  name                 = var.role_name
  description          = var.description
  assume_role_policy   = data.aws_iam_policy_document.assume_role.json
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, { Name = var.role_name })
}

resource "aws_iam_role_policy_attachment" "managed" {
  for_each = toset(var.policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

resource "aws_iam_policy" "inline" {
  count = var.inline_policy_json == null ? 0 : 1

  name        = "${var.role_name}-policy"
  description = "Inline permissions for ${var.role_name}"
  policy      = var.inline_policy_json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "inline" {
  count = var.inline_policy_json == null ? 0 : 1

  role       = aws_iam_role.this.name
  policy_arn = aws_iam_policy.inline[0].arn
}
