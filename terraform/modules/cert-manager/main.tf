# cert-manager and its Let's Encrypt ClusterIssuers.
#
# Issues and renews the TLS certificate the Ingress serves. Certificates are
# requested by annotating an Ingress with
#
#     cert-manager.io/cluster-issuer: letsencrypt-staging
#
# cert-manager watches for that annotation, creates a Certificate, solves an
# ACME challenge, and writes the result into the Secret named in the Ingress
# tls block. Nothing in Terraform waits for any of it.
#
# Why cert-manager rather than ACM
# --------------------------------
# ACM validates a certificate by looking up a DNS record in the public DNS
# system, and aws_acm_certificate_validation blocks `terraform apply` until it
# appears. Request a certificate before the registrar's nameservers point at
# Route53 and Terraform hangs for the full timeout, then fails.
#
# cert-manager is a controller, so it simply retries in the background. The
# apply finishes immediately and the certificate issues on its own once
# delegation propagates — which decouples "deploy the platform" from "update
# the nameservers at the registrar".
#
# Why DNS-01 rather than HTTP-01
# ------------------------------
# DNS-01 works before the site is publicly reachable, and it is the only
# challenge type that can issue a wildcard. It costs one IRSA role scoped to a
# single hosted zone.

resource "kubernetes_namespace_v1" "this" {
  metadata {
    name = var.namespace

    labels = {
      "app.kubernetes.io/name"       = "cert-manager"
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = var.chart_version
  namespace  = kubernetes_namespace_v1.this.metadata[0].name

  atomic          = true
  cleanup_on_fail = true
  timeout         = 600

  values = [yamlencode({
    # Installs the Certificate, ClusterIssuer, Order and Challenge CRDs. On
    # charts older than v1.15 this key is spelled `installCRDs: true`.
    crds = {
      enabled = true

      # Leave the CRDs behind if the release is removed. Deleting them would
      # cascade-delete every Certificate in the cluster along with the Secrets
      # holding the issued keys.
      keep = true
    }

    serviceAccount = {
      create = true
      name   = var.service_account_name
      annotations = var.irsa_role_arn == null ? {} : {
        "eks.amazonaws.com/role-arn" = var.irsa_role_arn
      }
    }

    # Without this the projected IRSA token is mounted with permissions the
    # non-root cert-manager process cannot read, and every Route53 call fails
    # with an error that looks like missing credentials rather than a file
    # permission problem.
    securityContext = {
      fsGroup = 1001
    }

    resources = {
      requests = { cpu = "20m", memory = "64Mi" }
      limits   = { memory = "128Mi" }
    }
  })]
}

# The ClusterIssuers, delivered as a small local chart.
#
# They cannot be kubernetes_manifest resources: that resource validates against
# the live cluster during `plan`, so it cannot create an object whose CRD will
# not exist until `apply`. Helm templates locally and applies at apply time, so
# it has no such restriction.
resource "helm_release" "issuers" {
  name      = "cert-manager-issuers"
  chart     = "${path.module}/chart"
  namespace = kubernetes_namespace_v1.this.metadata[0].name

  atomic          = true
  cleanup_on_fail = true
  timeout         = 300

  values = [yamlencode({
    email   = var.acme_email
    dnsZone = var.dns_zone_name

    aws = {
      region = var.aws_region

      # Pinning the zone ID saves cert-manager from searching every hosted zone
      # in the account, and lets the IAM policy stay scoped to just this one.
      hostedZoneID = var.dns_zone_id
    }
  })]

  depends_on = [helm_release.cert_manager]
}
