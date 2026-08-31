package httpx

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"
)

// RemoteError is returned when a downstream service answers with a non-2xx
// status. booking-service inspects Status to tell "sold out" (409) apart from
// "payment declined" (402) and from a genuine outage (5xx).
type RemoteError struct {
	Service string
	Status  int
	Code    string
	Message string

	// Body is the raw response payload. Do only decodes into its `out`
	// argument on success, so this is the only way to reach a domain object
	// returned alongside an error status — payment-service answers 402 with
	// the whole DECLINED payment record, and the reason the card was refused
	// is in there rather than in the error envelope.
	Body []byte
}

func (e *RemoteError) Error() string {
	return fmt.Sprintf("%s returned %d (%s): %s", e.Service, e.Status, e.Code, e.Message)
}

// Client is a small JSON-over-HTTP client for service-to-service calls.
//
// In the cluster BaseURL is a Kubernetes Service DNS name such as
// http://event-service:8080, which is the whole point of the exercise: no
// service discovery library, no hard-coded pod IPs, just DNS.
type Client struct {
	Service string
	BaseURL string
	Retries int

	hc *http.Client
}

// NewClient builds a client for one downstream service.
func NewClient(service, baseURL string, timeout time.Duration) *Client {
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   5 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 20,
		IdleConnTimeout:     90 * time.Second,
	}

	return &Client{
		Service: service,
		BaseURL: strings.TrimRight(baseURL, "/"),
		Retries: 2,
		hc:      &http.Client{Timeout: timeout, Transport: transport},
	}
}

// Do sends body as JSON to path and decodes a 2xx response into out. Either may
// be nil. Requests are retried on connection errors and 5xx responses; 4xx
// responses are returned immediately as a *RemoteError because retrying a
// client error only wastes time.
func (c *Client) Do(ctx context.Context, method, path string, body, out any) error {
	var payload []byte
	if body != nil {
		var err error
		if payload, err = json.Marshal(body); err != nil {
			return fmt.Errorf("marshal request for %s: %w", c.Service, err)
		}
	}

	var lastErr error
	for attempt := 0; attempt <= c.Retries; attempt++ {
		if attempt > 0 {
			// Linear backoff is plenty for a demo; the point is that the retry
			// respects context cancellation.
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Duration(attempt) * 200 * time.Millisecond):
			}
		}

		var reader io.Reader
		if payload != nil {
			reader = bytes.NewReader(payload)
		}

		req, err := http.NewRequestWithContext(ctx, method, c.BaseURL+path, reader)
		if err != nil {
			return fmt.Errorf("build request for %s: %w", c.Service, err)
		}
		req.Header.Set("Accept", "application/json")
		if payload != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		if rid := RequestIDFrom(ctx); rid != "" {
			req.Header.Set(RequestIDHeader, rid)
		}

		resp, err := c.hc.Do(req)
		if err != nil {
			lastErr = fmt.Errorf("call %s: %w", c.Service, err)
			continue
		}

		respBody, readErr := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
		resp.Body.Close()
		if readErr != nil {
			lastErr = fmt.Errorf("read %s response: %w", c.Service, readErr)
			continue
		}

		switch {
		case resp.StatusCode >= 200 && resp.StatusCode < 300:
			if out == nil || len(respBody) == 0 {
				return nil
			}
			if err := json.Unmarshal(respBody, out); err != nil {
				return fmt.Errorf("decode %s response: %w", c.Service, err)
			}
			return nil

		case resp.StatusCode >= 500:
			lastErr = remoteError(c.Service, resp.StatusCode, respBody)
			continue

		default:
			return remoteError(c.Service, resp.StatusCode, respBody)
		}
	}

	return lastErr
}

func remoteError(service string, status int, body []byte) *RemoteError {
	e := &RemoteError{Service: service, Status: status, Code: "upstream_error", Body: body}

	var parsed ErrorBody
	if err := json.Unmarshal(body, &parsed); err == nil && parsed.Error != "" {
		e.Code = parsed.Error
		e.Message = parsed.Message
		return e
	}

	e.Message = strings.TrimSpace(string(body))
	if e.Message == "" {
		e.Message = http.StatusText(status)
	}
	return e
}

// Ping checks the downstream /health endpoint. Services use it as a readiness
// check so that a pod does not accept traffic before its dependencies resolve.
func (c *Client) Ping(ctx context.Context) error {
	return c.Do(ctx, http.MethodGet, "/health", nil, nil)
}
