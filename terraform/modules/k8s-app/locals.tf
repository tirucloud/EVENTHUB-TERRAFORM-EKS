# Values shared by all five service files. Anything specific to one service
# lives in that service's own file instead.

locals {
  # Applied to every object, so `kubectl get all -l app.kubernetes.io/part-of=eventhub`
  # finds the whole application.
  common_labels = {
    "app.kubernetes.io/part-of"    = "eventhub"
    "app.kubernetes.io/managed-by" = "terraform"
    "eventhub.io/environment"      = var.environment
  }

  # <account>.dkr.ecr.<region>.amazonaws.com/eventhub:<service>-<tag>
  image = {
    for service in [
      "frontend-service",
      "event-service",
      "booking-service",
      "payment-service",
      "notification-service",
    ] : service => "${var.ecr_repository_url}:${service}-${var.image_tag}"
  }

  # Kubernetes Service DNS names. This is the entire service discovery story:
  # no registry, no sidecar, just names CoreDNS resolves inside the cluster.
  url = {
    frontend     = "http://frontend-service:8080"
    event        = "http://event-service:8080"
    booking      = "http://booking-service:8080"
    payment      = "http://payment-service:8080"
    notification = "http://notification-service:8080"
  }

  # Non-secret configuration common to every service, delivered as a ConfigMap
  # in each service file.
  common_config = {
    LOG_LEVEL   = var.log_level
    APP_VERSION = var.image_tag

    # Keep serving for 5s after SIGTERM while kube-proxy on other nodes removes
    # this pod from the Service endpoints. Without it a rolling update drops
    # requests. There is no preStop hook because the images are distroless and
    # have no shell to run `sleep` in — the services handle SIGTERM themselves.
    DRAIN_DELAY = "5s"
  }

  # A database per service on one PostgreSQL server. Sharing a server but not a
  # schema is the pragmatic middle ground: services stay independent at the data
  # level without four database servers to pay for and operate.
  database = {
    "event-service"        = "events"
    "booking-service"      = "bookings"
    "payment-service"      = "payments"
    "notification-service" = "notifications"
  }

  # Key inside the postgres-credentials Secret holding each connection string.
  db_secret_key = {
    for service, _ in local.database :
    service => "DATABASE_URL_${upper(replace(service, "-", "_"))}"
  }

  # Ingress annotations. Only frontend-service adds the cluster-issuer
  # annotation on top of these — see the comment in frontend-service.tf.
  ingress_annotations = {
    "traefik.ingress.kubernetes.io/router.entrypoints" = var.enable_tls ? "websecure" : "web"
    "traefik.ingress.kubernetes.io/router.tls"         = var.enable_tls ? "true" : "false"
  }
}
