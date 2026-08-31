# ==============================================================================
# payment-service — mock payment gateway
# ==============================================================================
#
# Authorises and refunds payments. Every decision it makes is reproducible on
# purpose: pay with the method "declined-card" and it always declines, which is
# what lets the booking saga's compensation path be demonstrated on demand.
#
# A declined card is answered with 402 Payment Required, not a 5xx. That
# distinction matters to the caller: 402 means "compensate", 5xx means "retry".
#
# Talks to: nothing. It is a leaf.
# ==============================================================================

locals {
  payment_service_name = "payment-service"

  payment_service_labels = merge(local.common_labels, {
    "app.kubernetes.io/name"      = local.payment_service_name
    "app.kubernetes.io/component" = "backend"
  })

  payment_service_selector = {
    "app.kubernetes.io/name" = local.payment_service_name
  }
}

# ------------------------------------------------------------------------------
# ConfigMap
# ------------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "payment_service" {
  metadata {
    name      = local.payment_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.payment_service_labels
  }

  data = merge(local.common_config, {
    # Raise this to make a share of payments fail at random. The quickest way to
    # show the booking saga compensating under sustained load.
    FAILURE_RATE_PERCENT = tostring(var.payment_failure_rate_percent)

    # Charges above this are declined with "amount_limit_exceeded". 50,000.00
    # in minor units.
    MAX_AMOUNT_CENTS = "5000000"

    # Simulated round trip to the processor, so payment latency is visible in
    # the booking flow and in the access logs.
    GATEWAY_LATENCY = "120ms"
  })
}

# ------------------------------------------------------------------------------
# Deployment
# ------------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "payment_service" {
  metadata {
    name      = local.payment_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.payment_service_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.payment_service_selector
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
        labels = local.payment_service_labels

        annotations = {
          "eventhub.io/config-hash" = sha256(jsonencode(kubernetes_config_map_v1.payment_service.data))
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
            match_labels = local.payment_service_selector
          }
        }

        container {
          name              = local.payment_service_name
          image             = local.image[local.payment_service_name]
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.payment_service.metadata[0].name
            }
          }

          env {
            name = "DATABASE_URL"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = local.db_secret_key[local.payment_service_name]
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

resource "kubernetes_service_v1" "payment_service" {
  metadata {
    name      = local.payment_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.payment_service_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.payment_service_selector

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

resource "kubernetes_horizontal_pod_autoscaler_v2" "payment_service" {
  count = var.enable_hpa ? 1 : 0

  metadata {
    name      = local.payment_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.payment_service_labels
  }

  spec {
    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.payment_service.metadata[0].name
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

resource "kubernetes_ingress_v1" "payment_service" {
  metadata {
    name        = local.payment_service_name
    namespace   = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels      = local.payment_service_labels
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
          path      = "/api/payments"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.payment_service.metadata[0].name

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

resource "kubernetes_pod_disruption_budget_v1" "payment_service" {
  metadata {
    name      = local.payment_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.payment_service_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.payment_service_selector
    }
  }
}
