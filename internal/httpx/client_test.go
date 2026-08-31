package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func TestDoDecodesSuccessfulResponse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		JSON(w, http.StatusOK, map[string]any{"id": "evt_1", "available_seats": 42})
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)

	var got struct {
		ID             string `json:"id"`
		AvailableSeats int    `json:"available_seats"`
	}
	if err := client.Do(context.Background(), http.MethodGet, "/api/events/evt_1", nil, &got); err != nil {
		t.Fatalf("Do: %v", err)
	}

	if got.ID != "evt_1" || got.AvailableSeats != 42 {
		t.Errorf("decoded %+v, want evt_1 with 42 seats", got)
	}
}

// booking-service branches on the status code to tell "sold out" from
// "declined" from "the service is down", so it has to survive the round trip.
func TestDoSurfacesRemoteErrorStatus(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		Error(w, http.StatusConflict, "insufficient_seats", "not enough seats remaining")
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)

	err := client.Do(context.Background(), http.MethodPost, "/api/events/evt_1/reserve", map[string]int{"seats": 2}, nil)

	var remote *RemoteError
	if !errors.As(err, &remote) {
		t.Fatalf("Do returned %T (%v), want a *RemoteError", err, err)
	}
	if remote.Status != http.StatusConflict {
		t.Errorf("Status = %d, want 409", remote.Status)
	}
	if remote.Code != "insufficient_seats" {
		t.Errorf("Code = %q, want insufficient_seats", remote.Code)
	}
}

// A 4xx is the server's considered answer. Asking again cannot change it, and
// retrying a reservation would risk holding seats twice.
func TestDoDoesNotRetryClientErrors(t *testing.T) {
	var calls atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		Error(w, http.StatusConflict, "insufficient_seats", "sold out")
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)
	_ = client.Do(context.Background(), http.MethodPost, "/api/events/evt_1/reserve", nil, nil)

	if got := calls.Load(); got != 1 {
		t.Errorf("upstream was called %d times, want exactly 1", got)
	}
}

// A 5xx usually means one unhealthy replica. Retrying lands on a different one.
func TestDoRetriesServerErrorsThenSucceeds(t *testing.T) {
	var calls atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if calls.Add(1) == 1 {
			Error(w, http.StatusBadGateway, "upstream_error", "try again")
			return
		}
		JSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)

	if err := client.Do(context.Background(), http.MethodGet, "/health", nil, nil); err != nil {
		t.Fatalf("Do: %v", err)
	}
	if got := calls.Load(); got != 2 {
		t.Errorf("upstream was called %d times, want 2 (one failure, one retry)", got)
	}
}

func TestDoGivesUpAfterRetries(t *testing.T) {
	var calls atomic.Int32

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		Error(w, http.StatusInternalServerError, "internal_error", "still broken")
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)
	client.Retries = 2

	if err := client.Do(context.Background(), http.MethodGet, "/health", nil, nil); err == nil {
		t.Fatal("Do returned nil, want an error after exhausting retries")
	}

	// One initial attempt plus two retries.
	if got := calls.Load(); got != 3 {
		t.Errorf("upstream was called %d times, want 3", got)
	}
}

func TestDoPropagatesRequestID(t *testing.T) {
	received := make(chan string, 1)

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		received <- r.Header.Get(RequestIDHeader)
		JSON(w, http.StatusOK, nil)
	}))
	defer server.Close()

	ctx := context.WithValue(context.Background(), requestIDKey, "req_abc123")
	client := NewClient("event-service", server.URL, 2*time.Second)

	if err := client.Do(ctx, http.MethodGet, "/health", nil, nil); err != nil {
		t.Fatalf("Do: %v", err)
	}

	if got := <-received; got != "req_abc123" {
		t.Errorf("%s = %q, want it forwarded as req_abc123", RequestIDHeader, got)
	}
}

func TestDoRespectsContextCancellation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		Error(w, http.StatusInternalServerError, "internal_error", "slow failure")
	}))
	defer server.Close()

	client := NewClient("event-service", server.URL, 2*time.Second)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	if err := client.Do(ctx, http.MethodGet, "/health", nil, nil); err == nil {
		t.Fatal("Do returned nil, want an error once the context expired")
	}
}

// payment-service answers a declined card with 402 and the full payment record
// rather than the standard {error, message} envelope. Do only decodes into
// `out` on success, so without RemoteError.Body the caller has no way to learn
// why the card was refused and reports a generic "upstream_error" instead.
func TestRemoteErrorCarriesResponseBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		JSON(w, http.StatusPaymentRequired, map[string]string{
			"id":             "pay_1",
			"status":         "DECLINED",
			"failure_reason": "card_declined",
		})
	}))
	defer server.Close()

	client := NewClient("payment-service", server.URL, 2*time.Second)
	err := client.Do(context.Background(), http.MethodPost, "/api/payments", map[string]int{"amount_cents": 100}, nil)

	var remote *RemoteError
	if !errors.As(err, &remote) {
		t.Fatalf("Do returned %T, want a *RemoteError", err)
	}
	if len(remote.Body) == 0 {
		t.Fatal("RemoteError.Body is empty, so the decline reason is unrecoverable")
	}

	var decoded struct {
		Status        string `json:"status"`
		FailureReason string `json:"failure_reason"`
	}
	if err := json.Unmarshal(remote.Body, &decoded); err != nil {
		t.Fatalf("could not decode the error body: %v", err)
	}
	if decoded.FailureReason != "card_declined" {
		t.Errorf("failure_reason = %q, want card_declined", decoded.FailureReason)
	}
}
