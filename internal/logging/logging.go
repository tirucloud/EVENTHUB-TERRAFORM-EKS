// Package logging builds the structured logger shared by every service.
//
// Output is JSON on a single line so that CloudWatch, Loki, or `kubectl logs`
// can parse it without a sidecar.
package logging

import (
	"log/slog"
	"os"
	"strings"

	"github.com/tirucloud/eventhub/internal/config"
)

// New returns a JSON logger tagged with the service name. The level comes from
// LOG_LEVEL (debug|info|warn|error) and defaults to info.
func New(service string) *slog.Logger {
	var level slog.Level
	switch strings.ToLower(config.String("LOG_LEVEL", "info")) {
	case "debug":
		level = slog.LevelDebug
	case "warn", "warning":
		level = slog.LevelWarn
	case "error":
		level = slog.LevelError
	default:
		level = slog.LevelInfo
	}

	handler := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	logger := slog.New(handler).With(
		slog.String("service", service),
		slog.String("version", config.String("APP_VERSION", "dev")),
	)

	// Anything that reaches the standard library logger (net/http internals,
	// third-party packages) lands in the same JSON stream.
	slog.SetDefault(logger)
	return logger
}
