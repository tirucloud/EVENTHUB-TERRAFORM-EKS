package httpx

import (
	"context"
	"net/http"
	"time"
)

// Checker reports whether a dependency is usable right now.
type Checker func(context.Context) error

// Health always answers 200. It is the liveness probe: it proves the process is
// running and its scheduler is not wedged. It deliberately does not check
// dependencies — a database outage should not make Kubernetes restart every pod.
func Health(service, version string) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		JSON(w, http.StatusOK, map[string]string{
			"status":  "ok",
			"service": service,
			"version": version,
		})
	})
}

// Ready runs every registered check and answers 503 if any of them fail. It is
// the readiness probe: a failing dependency takes the pod out of the Service
// endpoints without restarting it.
func Ready(checks map[string]Checker) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// A draining pod is never ready, regardless of dependency health.
		if draining.Load() {
			JSON(w, http.StatusServiceUnavailable, map[string]any{"status": "draining"})
			return
		}

		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		results := make(map[string]string, len(checks))
		status := http.StatusOK

		for name, check := range checks {
			if err := check(ctx); err != nil {
				results[name] = "error: " + err.Error()
				status = http.StatusServiceUnavailable
				continue
			}
			results[name] = "ok"
		}

		body := map[string]any{"checks": results}
		if status == http.StatusOK {
			body["status"] = "ready"
		} else {
			body["status"] = "not_ready"
		}
		JSON(w, status, body)
	})
}
