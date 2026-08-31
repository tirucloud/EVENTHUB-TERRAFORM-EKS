# ==============================================================================
# frontend-service — the UI, and the owner of the TLS certificate
# ==============================================================================
#
# A Go binary with the entire single-page app compiled into it via go:embed, so
# the container is one static file with no web server to configure and nothing
# to mount at runtime.
#
# It can also reverse-proxy /api/* to the backends, which is how it works under
# docker compose. In the cluster the Ingresses route those paths directly to
# each service, so the proxy is a fallback rather than the live path. Keeping
# both means the same image runs in both places with no conditional logic.
#
# Two things make this file different from the other four:
#
#   1. No database. It holds no state of its own.
#   2. It carries the cert-manager annotation, so it is the one Ingress that
#      requests the shared TLS certificate. See the note above the Ingress.
# ==============================================================================

locals {
  frontend_service_name = "frontend-service"

  frontend_service_labels = merge(local.common_labels, {
    "app.kubernetes.io/name"      = local.frontend_service_name
    "app.kubernetes.io/component" = "frontend"
  })

  frontend_service_selector = {
    "app.kubernetes.io/name" = local.frontend_service_name
  }
}

# ------------------------------------------------------------------------------
# ConfigMap
# ------------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "frontend_service" {
  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels
  }

  data = merge(local.common_config, {
    EVENT_SERVICE_URL        = local.url.event
    BOOKING_SERVICE_URL      = local.url.booking
    PAYMENT_SERVICE_URL      = local.url.payment
    NOTIFICATION_SERVICE_URL = local.url.notification
  })
}

# ------------------------------------------------------------------------------
# Deployment
# ------------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "frontend_service" {
  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.frontend_service_selector
    }

    strategy {
      type = "RollingUpdate"

      rolling_update {
        max_surge       = "25%"
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = local.frontend_service_labels

        annotations = {
          "eventhub.io/config-hash" = sha256(jsonencode(kubernetes_config_map_v1.frontend_service.data))
        }
      }

      spec {
        automount_service_account_token  = false
        termination_grace_period_seconds = 40

        security_context {
          run_as_non_root = true
          run_as_user     = 65532
          run_as_group    = 65532
          fs_group        = 65532

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = local.frontend_service_selector
          }
        }

        container {
          name              = local.frontend_service_name
          image             = local.image[local.frontend_service_name]
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.frontend_service.metadata[0].name
            }
          }

          # Reported by /api/meta and shown in the UI footer, which makes
          # replica counts and HPA scaling visible without running kubectl.
          env {
            name = "POD_NAME"

            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }

          liveness_probe {
            http_get {
              path = "/health"
              port = 8080
            }

            initial_delay_seconds = 5
            period_seconds        = 10
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          # Readiness here is deliberately local: it checks nothing downstream.
          # If a backend is down the UI should still load and show the error,
          # rather than the whole site disappearing from the load balancer.
          readiness_probe {
            http_get {
              path = "/ready"
              port = 8080
            }

            initial_delay_seconds = 2
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 3
          }

          startup_probe {
            http_get {
              path = "/health"
              port = 8080
            }

            period_seconds    = 3
            failure_threshold = 20
          }

          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [spec[0].replicas]
  }
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "frontend_service" {
  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.frontend_service_selector

    port {
      name        = "http"
      port        = 8080
      target_port = 8080
      protocol    = "TCP"
    }
  }
}

# ------------------------------------------------------------------------------
# HorizontalPodAutoscaler
# ------------------------------------------------------------------------------

resource "kubernetes_horizontal_pod_autoscaler_v2" "frontend_service" {
  count = var.enable_hpa ? 1 : 0

  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels
  }

  spec {
    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.frontend_service.metadata[0].name
    }

    metric {
      type = "Resource"

      resource {
        name = "cpu"

        target {
          type                = "Utilization"
          average_utilization = var.hpa_cpu_target_percent
        }
      }
    }

    behavior {
      scale_up {
        stabilization_window_seconds = 30
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
      }

      scale_down {
        stabilization_window_seconds = 300
        select_policy                = "Min"

        policy {
          type           = "Pods"
          value          = 1
          period_seconds = 60
        }
      }
    }
  }
}

# ------------------------------------------------------------------------------
# Ingress — the catch-all, and the one that owns the certificate
#
# All five Ingresses share the same host and the same TLS Secret, but only this
# one carries the cert-manager.io/cluster-issuer annotation. That is
# intentional: cert-manager creates one Certificate per annotated Ingress, so
# annotating all five would fire five simultaneous requests for the same name
# and exhaust the Let's Encrypt rate limit for no benefit.
#
# One Ingress requests the certificate; Traefik loads the resulting Secret into
# its certificate store and serves it for every router matching that hostname.
#
# The path is "/" and it still does not shadow the /api/* rules, because Traefik
# orders rules by path specificity rather than by declaration order.
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "frontend_service" {
  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels

    annotations = merge(
      local.ingress_annotations,
      var.enable_tls ? {
        "cert-manager.io/cluster-issuer" = var.cluster_issuer
      } : {},
    )
  }

  spec {
    ingress_class_name = var.ingress_class_name

    dynamic "tls" {
      for_each = var.enable_tls ? [1] : []

      content {
        hosts       = [var.app_fqdn]
        secret_name = var.tls_secret_name
      }
    }

    rule {
      host = var.app_fqdn

      http {
        path {
          path      = "/"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.frontend_service.metadata[0].name

              port {
                number = 8080
              }
            }
          }
        }
      }
    }
  }
}

# ------------------------------------------------------------------------------
# PodDisruptionBudget
# ------------------------------------------------------------------------------

resource "kubernetes_pod_disruption_budget_v1" "frontend_service" {
  metadata {
    name      = local.frontend_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.frontend_service_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.frontend_service_selector
    }
  }
}
