// Package db opens the shared PostgreSQL connection pool.
//
// Every service degrades to an in-memory store when DATABASE_URL is unset, so
// the stack runs with zero dependencies during development and switches to the
// Postgres StatefulSet (backed by an EBS gp3 volume) inside the cluster purely
// by setting one environment variable.
package db

import (
	"context"
	"fmt"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/tirucloud/eventhub/internal/config"
)

// Connect dials PostgreSQL and retries until the pool is usable or ctx expires.
//
// The retry loop is not optional in Kubernetes: application pods and the
// Postgres StatefulSet start at the same time, so the first few attempts will
// always fail while the database is still initialising.
func Connect(ctx context.Context, dsn string, logger *slog.Logger) (*pgxpool.Pool, error) {
	cfg, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse DATABASE_URL: %w", err)
	}

	cfg.MaxConns = int32(config.Int("DB_MAX_CONNS", 10))
	cfg.MinConns = int32(config.Int("DB_MIN_CONNS", 1))
	cfg.MaxConnLifetime = time.Hour
	cfg.MaxConnIdleTime = 30 * time.Minute
	cfg.HealthCheckPeriod = time.Minute

	var (
		attempts = config.Int("DB_CONNECT_ATTEMPTS", 30)
		delay    = config.Duration("DB_CONNECT_DELAY", 2*time.Second)
		lastErr  error
	)

	for attempt := 1; attempt <= attempts; attempt++ {
		pool, err := pgxpool.NewWithConfig(ctx, cfg)
		if err != nil {
			lastErr = err
		} else {
			pingCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
			err = pool.Ping(pingCtx)
			cancel()

			if err == nil {
				logger.Info("connected to postgres",
					slog.Int("attempt", attempt),
					slog.String("host", cfg.ConnConfig.Host),
					slog.String("database", cfg.ConnConfig.Database),
				)
				return pool, nil
			}
			pool.Close()
			lastErr = err
		}

		logger.Warn("postgres not ready, retrying",
			slog.Int("attempt", attempt),
			slog.Int("max_attempts", attempts),
			slog.Any("error", lastErr),
		)

		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}
	}

	return nil, fmt.Errorf("postgres unreachable after %d attempts: %w", attempts, lastErr)
}
