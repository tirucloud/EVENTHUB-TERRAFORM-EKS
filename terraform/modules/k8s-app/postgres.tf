# PostgreSQL as a StatefulSet on an EBS gp3 volume.
#
# This is what gives the EBS CSI driver something real to do. The chain worth
# following during a session:
#
#   StatefulSet volumeClaimTemplate
#     -> PersistentVolumeClaim (Pending, waiting for a consumer)
#       -> pod scheduled to a node in, say, us-east-1b
#         -> EBS CSI controller calls ec2:CreateVolume in us-east-1b, using
#            credentials from its IRSA role
#           -> PersistentVolume created and attached to that node
#             -> pod starts
#
# Delete the pod and it returns with the same PVC, volume and data. Delete the
# StatefulSet and the PVC survives on purpose.
#
# Say the caveat out loud: a single-replica StatefulSet is not a highly
# available database. It is the right shape for a workshop and the wrong shape
# for production, where this would be RDS Multi-AZ or an operator that manages
# replication and failover.

resource "random_password" "postgres" {
  length = 24

  # No special characters, so the password is safe to embed in a connection URL
  # without escaping.
  special = false
}

resource "kubernetes_secret_v1" "postgres" {
  metadata {
    name      = "postgres-credentials"
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.common_labels
  }

  data = merge(
    {
      POSTGRES_USER     = "eventhub"
      POSTGRES_PASSWORD = random_password.postgres.result
      POSTGRES_DB       = "eventhub"
    },

    # One connection string per service, each pointing at that service's own
    # database. Keeping them here means the application Deployments never
    # reference the password itself, only a secretKeyRef.
    {
      for service, database in local.database :
      local.db_secret_key[service] =>
      "postgres://eventhub:${random_password.postgres.result}@postgres.${var.namespace}.svc.cluster.local:5432/${database}?sslmode=disable"
    },
  )

  type = "Opaque"
}

# The same script docker-compose mounts locally, so databases are created
# identically in both places and there is only one file to keep correct.
resource "kubernetes_config_map_v1" "postgres_init" {
  metadata {
    name      = "postgres-init"
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = local.common_labels
  }

  data = {
    "10-init-databases.sh" = file("${path.module}/../../../deploy/postgres/init-databases.sh")
  }
}

# Headless Service: no cluster IP, so DNS resolves straight to the pod. That is
# what gives a StatefulSet pod its stable identity, postgres-0.postgres.
resource "kubernetes_service_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = "postgres" })
  }

  spec {
    cluster_ip = "None"
    selector   = { "app.kubernetes.io/name" = "postgres" }

    port {
      name        = "postgres"
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_stateful_set_v1" "postgres" {
  metadata {
    name      = "postgres"
    namespace = kubernetes_namespace_v1.eventhub.metadata[0].name
    labels    = merge(local.common_labels, { "app.kubernetes.io/name" = "postgres" })
  }

  spec {
    service_name = kubernetes_service_v1.postgres.metadata[0].name
    replicas     = 1

    selector {
      match_labels = { "app.kubernetes.io/name" = "postgres" }
    }

    template {
      metadata {
        labels = merge(local.common_labels, { "app.kubernetes.io/name" = "postgres" })
      }

      spec {
        automount_service_account_token  = false
        termination_grace_period_seconds = 60

        # uid/gid 70 is the postgres user in the Alpine image. fs_group makes
        # the kubelet chown the mounted volume to that group, which is what
        # lets the database run as a non-root user under the restricted Pod
        # Security Standard.
        security_context {
          run_as_non_root = true
          run_as_user     = 70
          run_as_group    = 70
          fs_group        = 70

          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name              = "postgres"
          image             = var.postgres_image
          image_pull_policy = "IfNotPresent"

          port {
            name           = "postgres"
            container_port = 5432
          }

          env_from {
            secret_ref {
              name = kubernetes_secret_v1.postgres.metadata[0].name
            }
          }

          # A subdirectory, not the mount point itself. EBS volumes arrive with
          # a lost+found directory, and initdb refuses to run in a directory
          # that is not empty.
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }

          volume_mount {
            name       = "init"
            mount_path = "/docker-entrypoint-initdb.d"
            read_only  = true
          }

          # The image needs a writable socket directory and /tmp. Explicit
          # emptyDirs keep the rest of the filesystem untouched.
          volume_mount {
            name       = "run"
            mount_path = "/var/run/postgresql"
          }

          volume_mount {
            name       = "tmp"
            mount_path = "/tmp"
          }

          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "eventhub", "-d", "eventhub"]
            }

            initial_delay_seconds = 30
            period_seconds        = 15
            timeout_seconds       = 5
            failure_threshold     = 4
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "eventhub", "-d", "eventhub"]
            }

            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 6
          }

          resources {
            requests = {
              cpu    = var.postgres_resources.cpu_request
              memory = var.postgres_resources.memory_request
            }
            limits = {
              memory = var.postgres_resources.memory_limit
            }
          }

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true

            capabilities {
              drop = ["ALL"]
            }
          }
        }

        volume {
          name = "init"

          config_map {
            name         = kubernetes_config_map_v1.postgres_init.metadata[0].name
            default_mode = "0555"
          }
        }

        volume {
          name = "run"
          empty_dir {}
        }

        volume {
          name = "tmp"
          empty_dir {}
        }
      }
    }

    # The PVC this generates is named data-postgres-0 and deliberately outlives
    # the StatefulSet. `terraform destroy` will not remove it; delete it by hand
    # when you want the data gone.
    volume_claim_template {
      metadata {
        name   = "data"
        labels = local.common_labels
      }

      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = kubernetes_storage_class_v1.gp3.metadata[0].name

        resources {
          requests = {
            storage = var.postgres_storage_size
          }
        }
      }
    }
  }

  # Creating the volume, formatting it and running initdb takes longer than the
  # provider's default patience.
  timeouts {
    create = "10m"
    update = "10m"
  }
}
