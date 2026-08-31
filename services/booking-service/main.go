// Command booking-service orchestrates the EventHub booking saga across
// event-service, payment-service and notification-service.
package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"time"

	"github.com/vijaygiduthuri/eventhub/internal/config"
	"github.com/vijaygiduthuri/eventhub/internal/db"
	"github.com/vijaygiduthuri/eventhub/internal/httpx"
	"github.com/vijaygiduthuri/eventhub/internal/logging"
)

const serviceName = "booking-service"

func main() {
	logger := logging.New(serviceName)

	if err := run(logger); err != nil {
		logger.Error("service exited with error", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()

	store, err := openStore(ctx, logger)
	if err != nil {
		return err
	}
	defer store.Close()

	// In the cluster these resolve to Kubernetes Services; under docker compose
	// they resolve to compose service names. Same image, different ConfigMap.
	downstream := newClients(
		config.String("EVENT_SERVICE_URL", "http://event-service:8080"),
		config.String("PAYMENT_SERVICE_URL", "http://payment-service:8080"),
		config.String("NOTIFICATION_SERVICE_URL", "http://notification-service:8080"),
		config.Duration("DOWNSTREAM_TIMEOUT", 5*time.Second),
	)

	a := &api{
		store:        store,
		orchestrator: &orchestrator{store: store, clients: downstream, logger: logger},
		logger:       logger,
	}

	mux := http.NewServeMux()
	a.routes(mux)
	mux.Handle("GET /health", httpx.Health(serviceName, config.String("APP_VERSION", "dev")))

	// Readiness covers the store plus both hard dependencies. notification is
	// deliberately absent: the booking flow degrades gracefully without it, so
	// it should not keep this pod out of the load balancer.
	mux.Handle("GET /ready", httpx.Ready(map[string]httpx.Checker{
		"store":           store.Ping,
		"event-service":   downstream.events.Ping,
		"payment-service": downstream.payments.Ping,
	}))

	handler := httpx.Chain(mux,
		httpx.RequestID,
		httpx.AccessLog(logger),
		httpx.Recover(logger),
		httpx.CORS,
	)

	return httpx.Run(httpx.ServerOptions{Handler: handler, Logger: logger})
}

func openStore(ctx context.Context, logger *slog.Logger) (Store, error) {
	dsn := config.String("DATABASE_URL", "")
	if dsn == "" {
		logger.Warn("DATABASE_URL is not set, falling back to in-memory store; data will not survive a restart")
		return newMemoryStore(), nil
	}

	pool, err := db.Connect(ctx, dsn, logger)
	if err != nil {
		return nil, err
	}

	store, err := newPostgresStore(ctx, pool)
	if err != nil {
		pool.Close()
		return nil, err
	}
	return store, nil
}
