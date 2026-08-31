// Command payment-service authorises and refunds payments for EventHub using a
// mock gateway with reproducible outcomes.
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

const serviceName = "payment-service"

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

	a := &api{store: store, gateway: newGateway(), logger: logger}

	mux := http.NewServeMux()
	a.routes(mux)
	mux.Handle("GET /health", httpx.Health(serviceName, config.String("APP_VERSION", "dev")))
	mux.Handle("GET /ready", httpx.Ready(map[string]httpx.Checker{"store": store.Ping}))

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
