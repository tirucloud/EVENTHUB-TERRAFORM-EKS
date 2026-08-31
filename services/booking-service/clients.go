package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/tirucloud/eventhub/internal/httpx"
)

// clients bundles the three downstream services booking-service depends on.
//
// Each base URL is a Kubernetes Service DNS name in the cluster
// (http://event-service:8080) and a compose service name locally. Nothing in
// this file knows about pods, nodes, or IP addresses.
type clients struct {
	events   *httpx.Client
	payments *httpx.Client
	notifier *httpx.Client
}

func newClients(eventURL, paymentURL, notificationURL string, timeout time.Duration) *clients {
	return &clients{
		events:   httpx.NewClient("event-service", eventURL, timeout),
		payments: httpx.NewClient("payment-service", paymentURL, timeout),
		notifier: httpx.NewClient("notification-service", notificationURL, timeout),
	}
}

// getEvent fetches the event so we can price the booking from the source of
// truth rather than trusting a price supplied by the browser.
func (c *clients) getEvent(ctx context.Context, eventID string) (remoteEvent, error) {
	var event remoteEvent
	err := c.events.Do(ctx, http.MethodGet, "/api/events/"+eventID, nil, &event)
	return event, err
}

// reserveSeats holds inventory before any money moves.
func (c *clients) reserveSeats(ctx context.Context, eventID string, seats int) error {
	body := map[string]int{"seats": seats}
	return c.events.Do(ctx, http.MethodPost, "/api/events/"+eventID+"/reserve", body, nil)
}

// releaseSeats is the compensating action for reserveSeats.
func (c *clients) releaseSeats(ctx context.Context, eventID string, seats int) error {
	body := map[string]int{"seats": seats}
	return c.events.Do(ctx, http.MethodPost, "/api/events/"+eventID+"/release", body, nil)
}

// charge attempts payment. A declined card surfaces as a *httpx.RemoteError
// with status 402, which the saga treats as a business failure rather than an
// outage.
func (c *clients) charge(ctx context.Context, b Booking, method string) (remotePayment, error) {
	body := map[string]any{
		"booking_id":   b.ID,
		"amount_cents": b.AmountCents,
		"currency":     b.Currency,
		"method":       method,
	}

	var payment remotePayment
	err := c.payments.Do(ctx, http.MethodPost, "/api/payments", body, &payment)

	// A decline is a 402, so Do returns an error and leaves `payment` empty --
	// but payment-service still sent back the full record, and its
	// failure_reason is what the customer needs to be told. Recover it from the
	// error body so the booking records "card_declined" rather than a generic
	// "upstream_error".
	if err != nil {
		var remote *httpx.RemoteError
		if errors.As(err, &remote) && len(remote.Body) > 0 {
			// Best effort: if the body is not a payment record, the caller
			// still gets the original error and a generic reason.
			_ = json.Unmarshal(remote.Body, &payment)
		}
	}

	return payment, err
}

// refund is the compensating action for charge.
func (c *clients) refund(ctx context.Context, paymentID string) error {
	return c.payments.Do(ctx, http.MethodPost, "/api/payments/"+paymentID+"/refund", nil, nil)
}

// notify sends a customer message. Callers treat failures as non-fatal: a
// booking that is paid for and confirmed must not be rolled back just because
// the email did not go out.
func (c *clients) notify(ctx context.Context, b Booking, subject, message string) error {
	body := map[string]string{
		"channel":    "email",
		"recipient":  b.CustomerEmail,
		"subject":    subject,
		"body":       message,
		"booking_id": b.ID,
		"event_id":   b.EventID,
	}
	return c.notifier.Do(ctx, http.MethodPost, "/api/notifications", body, nil)
}
