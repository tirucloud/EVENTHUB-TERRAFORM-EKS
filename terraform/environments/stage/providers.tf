provider "aws" {
  region = var.aws_region

  # Applied to every resource that supports tagging, so no module has to repeat
  # them. Module-level tags merge on top.
  default_tags {
    tags = {
      Project     = var.project
      Environment = var.environment
      ManagedBy   = "terraform"
      Repository  = "EventHub-Terraform-EKS"
    }
  }
}

# ------------------------------------------------------------------------------
# Kubernetes and Helm
#
# Both are configured from the eks module's outputs, which do not exist until
# the cluster does. That is why the first run of a fresh environment has to be
# staged with -target:
#
#     terraform apply -target=module.vpc
#     terraform apply -target=module.eks
#     ...
#
# A targeted apply prunes the graph, so these providers are never configured
# while their inputs are still unknown. Once the cluster exists the values come
# from state and a plain `terraform apply` works normally.
#
# See the README for the full ordered list, or just use the Makefile:
#
#     make dev-infra      # everything up to and including the add-ons
#     make dev-apps       # cert-manager, Traefik, the five services
# ------------------------------------------------------------------------------

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  # `aws eks get-token` is called at request time, so the credential is always
  # fresh. The alternative, data.aws_eks_cluster_auth, bakes a token into the
  # plan — and those expire after 15 minutes, so any apply that waits on a load
  # balancer reliably fails partway through with "Unauthorized".
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}
