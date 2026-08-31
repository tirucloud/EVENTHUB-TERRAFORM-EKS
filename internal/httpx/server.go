package httpx

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os/signal"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/vijaygiduthuri/eventhub/internal/config"
)

// draining flips to true the moment SIGTERM arrives, which makes the readiness
// probe fail while the process is still serving in-flight requests.
var draining atomic.Bool

// ServerOptions tunes the shared HTTP server. The zero value is usable.
type ServerOptions struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// Handler is the fully decorated router.
	Handler http.Handler
	// Logger receives lifecycle events.
	Logger *slog.Logger
	// DrainDelay is how long to keep serving after SIGTERM before refusing new
	// connections. This covers the window where kube-proxy on other nodes has
	// not yet removed this pod from the Service endpoints.
	DrainDelay time.Duration
	// ShutdownTimeout bounds how long in-flight requests may take to finish.
	ShutdownTimeout time.Duration
}

// Run starts an HTTP server and blocks until SIGINT or SIGTERM, then shuts down
// gracefully.
//
// The sequence matters in Kubernetes and is worth walking through in the
// session:
//
//  1. SIGTERM arrives (kubelet has already started deleting the pod).
//  2. /ready starts failing, so the endpoints controller drops this pod.
//  3. We keep serving for DrainDelay, because kube-proxy on other nodes needs
//     a moment to notice. Skipping this step is the usual cause of 502s during
//     a rolling update.
//  4. Shutdown() stops accepting connections and waits for in-flight requests.
func Run(opts ServerOptions) error {
	if opts.Addr == "" {
		opts.Addr = ":" + config.String("PORT", "8080")
	}
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	if opts.DrainDelay == 0 {
		opts.DrainDelay = config.Duration("DRAIN_DELAY", 5*time.Second)
	}
	if opts.ShutdownTimeout == 0 {
		opts.ShutdownTimeout = config.Duration("SHUTDOWN_TIMEOUT", 25*time.Second)
	}

	srv := &http.Server{
		Addr:              opts.Addr,
		Handler:           opts.Handler,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      60 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	errCh := make(chan error, 1)
	go func() {
		opts.Logger.Info("http server listening", slog.String("addr", opts.Addr))
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
			return
		}
		errCh <- nil
	}()

	select {
	case err := <-errCh:
		return err
	case <-ctx.Done():
	}

	draining.Store(true)
	opts.Logger.Info("shutdown signal received, draining",
		slog.Duration("drain_delay", opts.DrainDelay))
	time.Sleep(opts.DrainDelay)

	shutdownCtx, cancel := context.WithTimeout(context.Background(), opts.ShutdownTimeout)
	defer cancel()

	if err := srv.Shutdown(shutdownCtx); err != nil {
		opts.Logger.Error("graceful shutdown failed, forcing close", slog.Any("error", err))
		return srv.Close()
	}

	opts.Logger.Info("shutdown complete")
	return nil
}
