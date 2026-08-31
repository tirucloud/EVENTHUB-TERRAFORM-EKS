// Command event-service owns the event catalogue and seat inventory for
// EventHub. It is the only service allowed to change how many seats remain.
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

const serviceName = "event-service"

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

	a := &api{store: store, logger: logger}

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

// openStore picks the backend from DATABASE_URL and seeds the demo catalogue
// when the store is empty.
func openStore(ctx context.Context, logger *slog.Logger) (Store, error) {
	dsn := config.String("DATABASE_URL", "")
	if dsn == "" {
		logger.Warn("DATABASE_URL is not set, falling back to in-memory store; data will not survive a restart")

		store := newMemoryStore()
		if err := seed(ctx, store, logger); err != nil {
			return nil, err
		}
		return store, nil
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

	n, err := store.count(ctx)
	if err != nil {
		store.Close()
		return nil, err
	}
	if n == 0 {
		if err := seed(ctx, store, logger); err != nil {
			store.Close()
			return nil, err
		}
	} else {
		logger.Info("existing catalogue found, skipping seed", slog.Int("events", n))
	}

	return store, nil
}

func seed(ctx context.Context, store Store, logger *slog.Logger) error {
	if !config.Bool("SEED_DATA", true) {
		logger.Info("seeding disabled via SEED_DATA=false")
		return nil
	}

	events := seedEvents()
	for _, e := range events {
		if _, err := store.Create(ctx, e); err != nil {
			return err
		}
	}

	logger.Info("seeded demo catalogue", slog.Int("events", len(events)))
	return nil
}
