# EKS managed add-ons.
#
# These are the cluster components AWS packages and upgrades for you. Compared
# to installing the same software with Helm, a managed add-on is version-aware
# of the control plane, upgraded through the EKS API, and visible in the
# console. Anything AWS does not package — Traefik, Cluster Autoscaler,
# ExternalDNS, the Load Balancer Controller — is installed with Helm in the
# 02-apps stack instead.
#
# resolve_conflicts_on_create = "OVERWRITE" matters: EKS bootstraps its own
# self-managed copies of vpc-cni, coredns and kube-proxy when a cluster is
# created. Without OVERWRITE, adopting them as add-ons fails with a conflict.

# Resolves the add-on version AWS recommends for this control plane version,
# so the cluster is never pinned to a version that has aged out.
data "aws_eks_addon_version" "this" {
  for_each = local.addons

  addon_name         = each.key
  kubernetes_version = var.kubernetes_version
  most_recent        = true
}

locals {
  # Add-ons that are always installed, mapped to the IRSA role they need
  # (null where the add-on needs no AWS API access of its own).
  base_addons = {
    # Pod networking. Every pod gets a routable VPC address from this.
    "vpc-cni" = {
      service_account_role_arn = null
      configuration_values     = null
    }

    # In-cluster DNS. This is what turns http://event-service:8080 into an IP,
    # so nothing in EventHub works without it.
    "coredns" = {
      service_account_role_arn = null
      configuration_values = jsonencode({
        replicaCount = 2
      })
    }

    # Service routing on each node.
    "kube-proxy" = {
      service_account_role_arn = null
      configuration_values     = null
    }

    # Provisions EBS volumes for PersistentVolumeClaims. The PostgreSQL
    # StatefulSet in 02-apps is what actually exercises it. Note the IRSA role:
    # the controller calls ec2:CreateVolume and ec2:AttachVolume, and gets those
    # permissions from its service account rather than from the node role.
    "aws-ebs-csi-driver" = {
      service_account_role_arn = var.ebs_csi_driver_role_arn
      configuration_values     = null
    }
  }

  # Supplies the resource metrics that `kubectl top` and every HorizontalPodAutoscaler
  # read. Without it an HPA sits at <unknown>/70% forever and never scales.
  metrics_server_addon = var.enable_metrics_server ? {
    "metrics-server" = {
      service_account_role_arn = null
      configuration_values     = null
    }
  } : {}

  # Pod Identity is the successor to IRSA: an agent on each node hands
  # credentials to pods without an OIDC round trip. Installed here so it is
  # available, while EventHub itself still uses IRSA because that is the
  # mechanism worth understanding first.
  pod_identity_addon = var.enable_pod_identity_agent ? {
    "eks-pod-identity-agent" = {
      service_account_role_arn = null
      configuration_values     = null
    }
  } : {}

  addons = merge(local.base_addons, local.metrics_server_addon, local.pod_identity_addon)
}

resource "aws_eks_addon" "this" {
  for_each = local.addons

  cluster_name  = var.cluster_name
  addon_name    = each.key
  addon_version = data.aws_eks_addon_version.this[each.key].version

  service_account_role_arn = each.value.service_account_role_arn
  configuration_values     = each.value.configuration_values

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # PRESERVE keeps the add-on's Kubernetes resources in place when the add-on is
  # removed from Terraform. For CNI in particular, deleting it out from under a
  # running cluster breaks networking on every node at once.
  preserve = true

  tags = var.tags
}
