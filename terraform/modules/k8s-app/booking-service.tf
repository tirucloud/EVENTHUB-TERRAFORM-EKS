# ==============================================================================
# booking-service — the saga orchestrator
# ==============================================================================
#
# The only service that talks to others, and the reason this application is
# worth deploying rather than a single "hello world".
#
# There is no distributed transaction here — there cannot be, since each service
# owns its own database. Instead every step that changes remote state has a
# compensating action, and the saga runs them in reverse on failure:
#
#   1. read the event              (no state change)
#   2. reserve seats               <- compensate: release
#   3. record a PENDING booking
#   4. charge the customer         <- compensate: refund
#   5. mark the booking CONFIRMED
#   6. notify the customer         (best effort, never rolls anything back)
#
# Talks to: event-service, payment-service, notification-service, over
# Kubernetes Service DNS.
# ==============================================================================

locals {
  booking_service_name = "booking-service"

  booking_service_labels = merge(local.common_labels, {
    "app.kubernetes.io/name"      = local.booking_service_name
    "app.kubernetes.io/component" = "backend"
  })

  booking_service_selector = {
    "app.kubernetes.io/name" = local.booking_service_name
  }
}

# ------------------------------------------------------------------------------
# ConfigMap
#
# The three downstream addresses are plain Kubernetes Service names. No service
# registry, no sidecar, no hard-coded pod IPs — CoreDNS resolves them, and a
# pod that moves to another node changes nothing here.
# ------------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "booking_service" {
  metadata {
    name      = local.booking_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.booking_service_labels
  }

  data = merge(local.common_config, {
    EVENT_SERVICE_URL        = local.url.event
    PAYMENT_SERVICE_URL      = local.url.payment
    NOTIFICATION_SERVICE_URL = local.url.notification

    # Per-call budget for downstream requests. Shorter than the ingress timeout
    # so a slow dependency surfaces as a clean 502 rather than a hung browser.
    DOWNSTREAM_TIMEOUT = "5s"
  })
}

# ------------------------------------------------------------------------------
# Deployment
# ------------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "booking_service" {
  metadata {
    name      = local.booking_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.booking_service_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.booking_service_selector
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
        labels = local.booking_service_labels

        annotations = {
          "eventhub.io/config-hash" = sha256(jsonencode(kubernetes_config_map_v1.booking_service.data))
        }
      }

      spec {
        automount_service_account_token = false

        # Longer than its peers. A booking in flight is holding a seat
        # reservation, so the pod is given time to finish or compensate rather
        # than being killed mid-saga.
        termination_grace_period_seconds = 60

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
            match_labels = local.booking_service_selector
          }
        }

        container {
          name              = local.booking_service_name
          image             = local.image[local.booking_service_name]
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.booking_service.metadata[0].name
            }
          }

          env {
            name = "DATABASE_URL"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = local.db_secret_key[local.booking_service_name]
              }
            }
          }

          env {
            name = "POD_NAME"

            value_from {
              field_ref {
                field_path = "metadata.name"
              }
            }
          }

          # Slightly larger than its peers: it holds open connections to three
          # downstream services for the duration of every booking.
          resources {
            requests = {
              cpu    = "100m"
              memory = "96Mi"
            }
            limits = {
              memory = "192Mi"
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

          # This service's /ready checks its database plus event-service and
          # payment-service, but deliberately not notification-service — the
          # booking flow degrades gracefully without notifications, so an
          # outage there should not take booking out of the load balancer.
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

  # Ordering here is a convenience, not a correctness requirement. Kubernetes
  # handles the real dependency: booking-service starts regardless and reports
  # itself unready until its dependencies answer, which is exactly what a
  # distributed system should do.
  depends_on = [
    kubernetes_stateful_set_v1.postgres,
    kubernetes_deployment_v1.event_service,
    kubernetes_deployment_v1.payment_service,
    kubernetes_deployment_v1.notification_service,
  ]
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "booking_service" {
  metadata {
    name      = local.booking_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.booking_service_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.booking_service_selector

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

resource "kubernetes_horizontal_pod_autoscaler_v2" "booking_service" {
  count = var.enable_hpa ? 1 : 0

  metadata {
    name      = local.booking_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.booking_service_labels
  }

  spec {
    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.booking_service.metadata[0].name
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
# Ingress
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "booking_service" {
  metadata {
    name        = local.booking_service_name
    namespace   = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels      = local.booking_service_labels
    annotations = local.ingress_annotations
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
          path      = "/api/bookings"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.booking_service.metadata[0].name

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

resource "kubernetes_pod_disruption_budget_v1" "booking_service" {
  metadata {
    name      = local.booking_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.booking_service_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.booking_service_selector
    }
  }
}
