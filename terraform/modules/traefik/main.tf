# Traefik ingress controller, plus the load balancer and DNS record in front
# of it.
#
# This module owns the whole public entry point:
#
#   Route53 record  ->  Network Load Balancer  ->  Traefik pods  ->  Services
#
# It creates the DNS record itself rather than leaving it to the caller,
# because the load balancer hostname only exists once Helm has finished. Keeping
# the record here means whatever owns the endpoint also owns the name that
# points at it.
#
# Traefik is installed with Helm, but the objects it routes are ordinary
# networking.k8s.io/v1 Ingress resources rather than Traefik IngressRoute custom
# resources. That keeps the application manifests portable, and it avoids a real
# Terraform problem: kubernetes_manifest validates custom resources against the
# live cluster during `plan`, so it cannot create an object whose CRD will not
# exist until `apply`.

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/name"       = "traefik"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "traefik" {
  name       = "traefik"
  repository = "https://traefik.github.io/charts"
  chart      = "traefik"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  atomic          = true
  cleanup_on_fail = true

  # Provisioning an NLB and waiting for it to go active takes a few minutes,
  # and `atomic` rolls the release back if the timeout is hit.
  timeout = var.timeout_seconds

  values = [yamlencode({
    deployment = {
      replicas = var.replicas
    }

    service = {
      type        = "LoadBalancer"
      annotations = local.service_annotations
    }

    ingressClass = {
      enabled        = true
      isDefaultClass = var.set_as_default_ingress_class
    }

    providers = {
      kubernetesIngress = {
        # Copies the load balancer hostname into the status of every Ingress
        # Traefik serves, which is what makes `kubectl get ingress` useful.
        publishedService = {
          enabled = true
        }
      }
    }

    # Static entrypoint configuration passed as CLI arguments rather than chart
    # values. Deliberate: these argument names come from Traefik itself and have
    # been stable for years, whereas the values keys that wrap them have been
    # renamed more than once between chart releases.
    additionalArguments = concat(
      var.redirect_http_to_https ? [
        # ":443", not "websecure".
        #
        # Naming the entrypoint looks more readable and is wrong in front of a
        # load balancer. Traefik builds the redirect URL from the target
        # entrypoint's own listen address, which inside the container is :8443 —
        # so users were sent to https://example.com:8443/, a port the NLB does
        # not listen on. The browser then hangs.
        #
        # Traefik never sees the Service's 443 -> 8443 mapping, so it has to be
        # told the public port explicitly.
        "--entrypoints.web.http.redirections.entryPoint.to=:${var.https_public_port}",
        "--entrypoints.web.http.redirections.entryPoint.scheme=https",
        "--entrypoints.web.http.redirections.entryPoint.permanent=true",
      ] : [],
      var.additional_arguments,
    )

    # Chart 40+ renamed these. It used to be logs.general.level and
    # logs.access.enabled; it is now log.level and a top-level accessLog.
    #
    # This is not a cosmetic difference. The chart ships a values.schema.json
    # that rejects unknown keys outright, so the old spelling does not quietly
    # fall back to defaults — `helm install` fails with
    # "additional properties 'logs' not allowed" and Terraform rolls the whole
    # release back. It is the clearest argument in this repo for pinning
    # chart_version rather than tracking latest.
    log = {
      level = var.log_level
    }

    accessLog = {
      enabled = var.enable_access_logs
    }

    resources = {
      requests = {
        cpu    = var.resources.cpu_request
        memory = var.resources.memory_request
      }
      limits = {
        memory = var.resources.memory_limit
      }
    }
  })]
}

locals {
  service_annotations = merge(
    {
      # "external" selects the AWS Load Balancer Controller rather than the
      # legacy in-tree provider.
      "service.beta.kubernetes.io/aws-load-balancer-type" = "external"

      # IP targets send traffic straight to the Traefik pod addresses. The
      # alternative, instance mode, routes via a NodePort on every node and
      # adds a hop plus a second round of health checks.
      "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"

      "service.beta.kubernetes.io/aws-load-balancer-scheme" = var.internal ? "internal" : "internet-facing"

      # Without this an NLB only serves targets in the zone the client resolved
      # to, so with two replicas across three zones a third of requests would
      # find nothing to talk to.
      "service.beta.kubernetes.io/aws-load-balancer-cross-zone-load-balancing-enabled" = "true"
    },

    # The security group from the security-groups module, so the rules opening
    # 80 and 443 are the ones written in Terraform.
    var.load_balancer_security_group_id == null ? {} : {
      "service.beta.kubernetes.io/aws-load-balancer-security-groups" = var.load_balancer_security_group_id

      # We wrote the node-side ingress rules ourselves, so the controller should
      # not also manage them. Leaving this true gives the same security group
      # two owners.
      "service.beta.kubernetes.io/aws-load-balancer-manage-backend-security-group-rules" = "false"
    },

    var.service_annotations,
  )
}

# Read back after Helm finishes. helm_release waits for its resources to become
# ready, and for a Service of type LoadBalancer that means waiting until AWS has
# reported the load balancer's DNS name — so this field is populated by the time
# the data source is read.
data "kubernetes_service_v1" "traefik" {
  metadata {
    name      = "traefik"
    namespace = kubernetes_namespace_v1.this.metadata[0].name
  }

  depends_on = [helm_release.traefik]
}

locals {
  load_balancer_hostname = try(
    data.kubernetes_service_v1.traefik.status[0].load_balancer[0].ingress[0].hostname,
    "",
  )
}

# The load balancer the AWS Load Balancer Controller created for the Traefik
# Service. Terraform did not create it, so it is not in state — but it can be
# found by the tags the controller stamps on every load balancer it manages.
#
# Needed for the ALIAS records below, which require the load balancer's
# canonical hosted zone ID as well as its DNS name.
data "aws_lb" "traefik" {
  tags = {
    "elbv2.k8s.aws/cluster" = var.cluster_name
    "service.k8s.aws/stack" = "${var.namespace}/traefik"
  }

  depends_on = [helm_release.traefik]
}

# ALIAS records, not CNAMEs.
#
# This is not a stylistic preference. **A CNAME is illegal at a zone apex** —
# DNS requires the apex to hold SOA and NS records, and a CNAME cannot coexist
# with other record types at the same name. So serving the application from
# thirucloud.shop rather than eventhub.thirucloud.shop rules CNAMEs out
# entirely.
#
# Route53's ALIAS is an AWS extension that solves it: it behaves like a CNAME
# but is resolved inside Route53 and returns A records, so it is legal at the
# apex. It also costs nothing to query and needs no TTL, since Route53 tracks
# the target's own TTL.
#
# ALIAS works for subdomains too, so this one form covers both cases.
resource "aws_route53_record" "app" {
  # Keyed on var.hostnames alone, which is known at plan time.
  #
  # This previously guarded on the load balancer hostname being non-empty, and
  # that broke every plan with "Invalid for_each argument": the hostname only
  # exists after Helm has run, so the *set of keys* became unknown. Terraform
  # requires for_each keys to be resolvable during plan — an unknown *value* is
  # fine, an unknown *key* is not. The hostname is therefore used only in
  # `records`, and its presence is asserted in the precondition below.
  for_each = toset(var.hostnames)

  zone_id = var.dns_zone_id
  name    = each.value
  type    = "A"

  alias {
    name    = data.aws_lb.traefik.dns_name
    zone_id = data.aws_lb.traefik.zone_id

    # Route53 stops returning this record if the load balancer's own health
    # checks are failing, rather than sending traffic into a black hole.
    evaluate_target_health = true
  }

  lifecycle {
    precondition {
      condition     = local.load_balancer_hostname != ""
      error_message = "Traefik's Service has no load balancer hostname yet. helm_release should have waited for it, so this usually means the AWS Load Balancer Controller could not create the NLB — check: kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller"
    }
  }
}
