# Cluster controllers that AWS does not package as managed add-ons, so they are
# installed with Helm instead.
#
# Both need to call the AWS API, and both get their credentials from an IRSA
# role rather than from the node. The annotation on the service account is the
# entire handshake — get the namespace or service account name wrong and the
# controller starts up healthy and then fails every AWS call with AccessDenied.

# ------------------------------------------------------------------------------
# AWS Load Balancer Controller
#
# Not a competing ingress controller. Traefik does the routing; this only
# notices a Service of type LoadBalancer and builds the Network Load Balancer
# for it, in IP target mode so traffic reaches the Traefik pods directly rather
# than hopping through a NodePort.
# ------------------------------------------------------------------------------

resource "helm_release" "aws_load_balancer_controller" {
  count = var.enable_aws_load_balancer_controller ? 1 : 0

  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.aws_load_balancer_controller_chart_version
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id

    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = var.aws_load_balancer_controller_role_arn
      }
    }

    resources = {
      requests = { cpu = "50m", memory = "96Mi" }
      limits   = { memory = "192Mi" }
    }
  })]

  depends_on = [aws_eks_addon.this]
}

# ------------------------------------------------------------------------------
# Cluster Autoscaler
#
# Watches for pods that cannot be scheduled and grows the node group; watches
# for underused nodes and shrinks it. It finds the node group through the two
# ASG tags the eks module sets, and its IAM policy only permits resizing ASGs
# that carry them.
# ------------------------------------------------------------------------------

resource "helm_release" "cluster_autoscaler" {
  count = var.enable_cluster_autoscaler ? 1 : 0

  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = var.cluster_autoscaler_chart_version
  namespace  = "kube-system"

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    autoDiscovery = {
      clusterName = var.cluster_name
    }
    awsRegion = var.aws_region

    rbac = {
      serviceAccount = {
        create = true
        name   = "cluster-autoscaler"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.cluster_autoscaler_role_arn
        }
      }
    }

    extraArgs = {
      # Keeps replicas balanced across zones when scaling up.
      balance-similar-node-groups = true

      # Both default to true, which makes a demo look broken: the autoscaler
      # refuses to drain a node running any kube-system pod or any pod with
      # local storage, so on a small cluster scale-down never happens and
      # everyone concludes it does not work. False is right here and deserves a
      # second look before production.
      skip-nodes-with-system-pods   = false
      skip-nodes-with-local-storage = false

      # Shortened from the 10-minute default so scale-down is observable within
      # a session.
      scale-down-unneeded-time   = var.scale_down_unneeded_time
      scale-down-delay-after-add = var.scale_down_delay_after_add
    }

    resources = {
      requests = { cpu = "50m", memory = "96Mi" }
      limits   = { memory = "256Mi" }
    }
  })]

  depends_on = [aws_eks_addon.this]
}
