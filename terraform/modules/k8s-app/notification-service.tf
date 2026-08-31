# ==============================================================================
# notification-service — the customer message log
# ==============================================================================
#
# Records every message EventHub would send a customer and exposes them as a
# feed the UI renders. There is no real SMTP or SMS provider: "delivery" is the
# structured log line plus the stored row.
#
# booking-service treats calls to this service as best effort. A booking that
# has been paid for and confirmed must never be rolled back because an email
# failed to send, so failures here are logged and swallowed.
#
# Talks to: nothing. It is a leaf.
# ==============================================================================

locals {
  notification_service_name = "notification-service"

  notification_service_labels = merge(local.common_labels, {
    "app.kubernetes.io/name"      = local.notification_service_name
    "app.kubernetes.io/component" = "backend"
  })

  notification_service_selector = {
    "app.kubernetes.io/name" = local.notification_service_name
  }
}

# ------------------------------------------------------------------------------
# ConfigMap
# ------------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "notification_service" {
  metadata {
    name      = local.notification_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.notification_service_labels
  }

  data = merge(local.common_config, {
    # Only used when DATABASE_URL is unset and the service falls back to its
    # in-memory ring buffer. Bounds it so a demo left running overnight cannot
    # exhaust the pod's memory limit.
    MEMORY_STORE_SIZE = "500"
  })
}

# ------------------------------------------------------------------------------
# Deployment
# ------------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "notification_service" {
  metadata {
    name      = local.notification_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.notification_service_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.notification_service_selector
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
        labels = local.notification_service_labels

        annotations = {
          "eventhub.io/config-hash" = sha256(jsonencode(kubernetes_config_map_v1.notification_service.data))
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
            match_labels = local.notification_service_selector
          }
        }

        container {
          name              = local.notification_service_name
          image             = local.image[local.notification_service_name]
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.notification_service.metadata[0].name
            }
          }

          env {
            name = "DATABASE_URL"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = local.db_secret_key[local.notification_service_name]
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

  depends_on = [kubernetes_stateful_set_v1.postgres]
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "notification_service" {
  metadata {
    name      = local.notification_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.notification_service_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.notification_service_selector

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

resource "kubernetes_horizontal_pod_autoscaler_v2" "notification_service" {
  count = var.enable_hpa ? 1 : 0

  metadata {
    name      = local.notification_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.notification_service_labels
  }

  spec {
    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.notification_service.metadata[0].name
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

resource "kubernetes_ingress_v1" "notification_service" {
  metadata {
    name        = local.notification_service_name
    namespace   = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels      = local.notification_service_labels
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
          path      = "/api/notifications"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.notification_service.metadata[0].name

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

resource "kubernetes_pod_disruption_budget_v1" "notification_service" {
  metadata {
    name      = local.notification_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.notification_service_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.notification_service_selector
    }
  }
}
