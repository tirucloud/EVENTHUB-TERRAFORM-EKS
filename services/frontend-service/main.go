// Command frontend-service serves the EventHub single-page UI and proxies API
// traffic to the four backend services.
//
// The UI assets are compiled into the binary with go:embed, so the container
// image is a single static file with no web server to configure and nothing to
// mount at runtime.
package main

import (
	"embed"
	"io/fs"
	"log/slog"
	"net/http"
	"os"

	"github.com/vijaygiduthuri/eventhub/internal/config"
	"github.com/vijaygiduthuri/eventhub/internal/httpx"
	"github.com/vijaygiduthuri/eventhub/internal/logging"
)

const serviceName = "frontend-service"

//go:embed static
var staticFiles embed.FS

func main() {
	logger := logging.New(serviceName)

	if err := run(logger); err != nil {
		logger.Error("service exited with error", slog.Any("error", err))
		os.Exit(1)
	}
}

func run(logger *slog.Logger) error {
	backends := []backend{
		{name: "event-service", prefix: "/api/events", target: config.String("EVENT_SERVICE_URL", "http://event-service:8080")},
		{name: "booking-service", prefix: "/api/bookings", target: config.String("BOOKING_SERVICE_URL", "http://booking-service:8080")},
		{name: "payment-service", prefix: "/api/payments", target: config.String("PAYMENT_SERVICE_URL", "http://payment-service:8080")},
		{name: "notification-service", prefix: "/api/notifications", target: config.String("NOTIFICATION_SERVICE_URL", "http://notification-service:8080")},
	}

	mux := http.NewServeMux()

	for _, b := range backends {
		proxy, err := newProxy(b, logger)
		if err != nil {
			return err
		}
		// Two patterns per backend: the collection itself and everything below it.
		mux.Handle(b.prefix, proxy)
		mux.Handle(b.prefix+"/", proxy)

		logger.Info("registered api route",
			slog.String("prefix", b.prefix),
			slog.String("upstream", b.target))
	}

	// Reports which pod served the request. The UI shows this in the footer,
	// which makes replica counts and HPA scaling visible during the session
	// without anyone having to run kubectl.
	mux.HandleFunc("GET /api/meta", func(w http.ResponseWriter, r *http.Request) {
		hostname, err := os.Hostname()
		if err != nil {
			hostname = "unknown"
		}
		httpx.JSON(w, http.StatusOK, map[string]string{
			"pod":     hostname,
			"service": serviceName,
			"version": config.String("APP_VERSION", "dev"),
		})
	})

	assets, err := fs.Sub(staticFiles, "static")
	if err != nil {
		return err
	}
	// Registered without a method so it stays strictly less specific than the
	// /api/* proxy patterns. ServeMux rejects "GET /" alongside "/api/events/"
	// as ambiguous: neither pattern wins on both method and path.
	// http.FileServerFS answers 405 for non-GET/HEAD on its own.
	mux.Handle("/", http.FileServerFS(assets))

	mux.Handle("GET /health", httpx.Health(serviceName, config.String("APP_VERSION", "dev")))
	// Readiness is intentionally local. If a backend is down the UI should still
	// load and show the error, rather than the whole site disappearing from the
	// load balancer.
	mux.Handle("GET /ready", httpx.Ready(nil))

	handler := httpx.Chain(mux,
		httpx.RequestID,
		httpx.AccessLog(logger),
		httpx.Recover(logger),
	)

	return httpx.Run(httpx.ServerOptions{Handler: handler, Logger: logger})
}
