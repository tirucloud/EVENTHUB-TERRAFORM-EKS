# ==============================================================================
# event-service — the event catalogue and seat inventory
# ==============================================================================
#
# Owns every seat in the system. Nothing else is allowed to change how many
# remain: booking-service has to call POST /api/events/{id}/reserve and can be
# told no. That constraint is what makes the booking saga necessary, and it is
# the clearest example in this project of a service owning its data rather than
# a shared table.
#
# Talks to: nothing. It is a leaf.
#
# Objects created here:
#   ConfigMap                  non-secret settings
#   Deployment                 with liveness, readiness and startup probes
#   Service                    ClusterIP, resolved as http://event-service:8080
#   HorizontalPodAutoscaler    scales on CPU, needs metrics-server
#   Ingress                    /api/events
#   PodDisruptionBudget        survives a node drain
# ==============================================================================

locals {
  event_service_name = "event-service"

  event_service_labels = merge(local.common_labels, {
    "app.kubernetes.io/name"      = local.event_service_name
    "app.kubernetes.io/component" = "backend"
  })

  event_service_selector = {
    "app.kubernetes.io/name" = local.event_service_name
  }
}

# ------------------------------------------------------------------------------
# ConfigMap
# ------------------------------------------------------------------------------

resource "kubernetes_config_map_v1" "event_service" {
  metadata {
    name      = local.event_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.event_service_labels
  }

  data = merge(local.common_config, {
    # Seeds the demo catalogue on first start, but only when the events table is
    # empty — so a database that survived an earlier run keeps its data.
    SEED_DATA = "true"
  })
}

# ------------------------------------------------------------------------------
# Deployment
# ------------------------------------------------------------------------------

resource "kubernetes_deployment_v1" "event_service" {
  metadata {
    name      = local.event_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.event_service_labels
  }

  spec {
    replicas = var.replicas

    selector {
      match_labels = local.event_service_selector
    }

    strategy {
      type = "RollingUpdate"

      rolling_update {
        # Add a pod before removing one, so capacity never dips during a deploy.
        max_surge       = "25%"
        max_unavailable = 0
      }
    }

    template {
      metadata {
        labels = local.event_service_labels

        # Restarts the pods whenever the ConfigMap changes. Without this a
        # config edit applies cleanly and changes nothing until something else
        # happens to restart the pod.
        annotations = {
          "eventhub.io/config-hash" = sha256(jsonencode(kubernetes_config_map_v1.event_service.data))
        }
      }

      spec {
        # Nothing here talks to the Kubernetes API, so the token would only ever
        # be a liability.
        automount_service_account_token = false

        # Long enough for DRAIN_DELAY plus in-flight requests to finish.
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

        # Spread replicas across zones where possible. ScheduleAnyway keeps a
        # small cluster working instead of leaving pods Pending.
        topology_spread_constraint {
          max_skew           = 1
          topology_key       = "topology.kubernetes.io/zone"
          when_unsatisfiable = "ScheduleAnyway"

          label_selector {
            match_labels = local.event_service_selector
          }
        }

        container {
          name              = local.event_service_name
          image             = local.image[local.event_service_name]
          image_pull_policy = var.image_pull_policy

          port {
            name           = "http"
            container_port = 8080
            protocol       = "TCP"
          }

          env_from {
            config_map_ref {
              name = kubernetes_config_map_v1.event_service.metadata[0].name
            }
          }

          # The connection string, including the password, never appears in the
          # Deployment — only a reference to the Secret key holding it.
          env {
            name = "DATABASE_URL"

            value_from {
              secret_key_ref {
                name = kubernetes_secret_v1.postgres.metadata[0].name
                key  = local.db_secret_key[local.event_service_name]
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

            # Memory is limited because exceeding it must kill the pod rather
            # than the node. CPU deliberately is not: a CPU limit throttles the
            # container even on an idle node, which surfaces as mysterious
            # latency nobody can explain.
            limits = {
              memory = "128Mi"
            }
          }

          # Liveness answers "is this process wedged". It never checks the
          # database — a database outage must not restart every pod at once.
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

          # Readiness answers "can this pod serve traffic right now", and does
          # check dependencies. A pod with a broken database leaves the Service
          # endpoints without being killed.
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

          # Gives a slow first start up to 60s before liveness starts counting.
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

  # Once the HPA is running it owns the replica count. Without this every apply
  # would reset the Deployment and undo the autoscaler's last decision.
  lifecycle {
    ignore_changes = [spec[0].replicas]
  }

  depends_on = [kubernetes_stateful_set_v1.postgres]
}

# ------------------------------------------------------------------------------
# Service
# ------------------------------------------------------------------------------

resource "kubernetes_service_v1" "event_service" {
  metadata {
    name      = local.event_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.event_service_labels
  }

  spec {
    type     = "ClusterIP"
    selector = local.event_service_selector

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

resource "kubernetes_horizontal_pod_autoscaler_v2" "event_service" {
  count = var.enable_hpa ? 1 : 0

  metadata {
    name      = local.event_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.event_service_labels
  }

  spec {
    min_replicas = var.hpa_min_replicas
    max_replicas = var.hpa_max_replicas

    scale_target_ref {
      api_version = "apps/v1"
      kind        = "Deployment"
      name        = kubernetes_deployment_v1.event_service.metadata[0].name
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
      # Scale up quickly — a queue of waiting users is the problem being solved.
      scale_up {
        stabilization_window_seconds = 30
        select_policy                = "Max"

        policy {
          type           = "Percent"
          value          = 100
          period_seconds = 30
        }
      }

      # Scale down slowly. Five minutes stops the autoscaler oscillating on
      # bursty traffic.
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
#
# Traefik orders rules by path specificity, so this longer prefix wins over
# frontend-service's catch-all "/" without any explicit priority.
#
# The tls block names the same Secret every service uses. Only
# frontend-service carries the cert-manager annotation that actually requests
# the certificate — see the comment there for why.
# ------------------------------------------------------------------------------

resource "kubernetes_ingress_v1" "event_service" {
  metadata {
    name        = local.event_service_name
    namespace   = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels      = local.event_service_labels
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
          path      = "/api/events"
          path_type = "Prefix"

          backend {
            service {
              name = kubernetes_service_v1.event_service.metadata[0].name

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

# Stops a node drain — from a Cluster Autoscaler scale-down or a node group
# upgrade — taking every replica down at once.
resource "kubernetes_pod_disruption_budget_v1" "event_service" {
  metadata {
    name      = local.event_service_name
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.event_service_labels
  }

  spec {
    min_available = 1

    selector {
      match_labels = local.event_service_selector
    }
  }
}
