package main

import (
	"log/slog"
	"net/http"
	"net/http/httputil"
	"net/url"
	"time"

	"github.com/vijaygiduthuri/eventhub/internal/httpx"
)

// backend describes one upstream service and the path prefix it owns.
type backend struct {
	name   string
	prefix string
	target string
}

// newProxy builds a reverse proxy for a single backend.
//
// This is what keeps the browser on one origin: the page is served from
// frontend-service, and every /api/* call is forwarded in-cluster over the
// Kubernetes Service DNS name. No CORS, no public endpoint per service, and
// only one hostname to put in Route53.
func newProxy(b backend, logger *slog.Logger) (http.Handler, error) {
	target, err := url.Parse(b.target)
	if err != nil {
		return nil, err
	}

	proxy := &httputil.ReverseProxy{
		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.SetURL(target)
			// Preserve the original path: backends expose the same /api/* paths
			// the browser calls, so no rewriting is needed.
			pr.Out.Host = target.Host
			pr.SetXForwarded()

			// Propagate the request ID so one booking is traceable end to end.
			if rid := httpx.RequestIDFrom(pr.In.Context()); rid != "" {
				pr.Out.Header.Set(httpx.RequestIDHeader, rid)
			}
		},

		Transport: &http.Transport{
			Proxy:                 http.ProxyFromEnvironment,
			MaxIdleConns:          100,
			MaxIdleConnsPerHost:   20,
			IdleConnTimeout:       90 * time.Second,
			ResponseHeaderTimeout: 15 * time.Second,
		},

		// A dead backend must not produce Go's default plain-text 502; the SPA
		// expects the same JSON error envelope every service returns.
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			logger.Error("upstream request failed",
				slog.String("backend", b.name),
				slog.String("path", r.URL.Path),
				slog.Any("error", err),
				slog.String("request_id", httpx.RequestIDFrom(r.Context())),
			)
			httpx.Error(w, http.StatusBadGateway, "upstream_unavailable", b.name+" is unavailable")
		},
	}

	return proxy, nil
}
