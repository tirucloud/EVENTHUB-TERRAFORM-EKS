package main

import (
	"errors"
	"strings"
	"time"
)

// Payment status values. A payment is terminal the moment it is created:
// either the mock gateway authorised it or it declined it.
const (
	StatusAuthorized = "AUTHORIZED"
	StatusDeclined   = "DECLINED"
	StatusRefunded   = "REFUNDED"
)

// Payment records one attempt to charge a customer for a booking.
type Payment struct {
	ID            string    `json:"id"`
	BookingID     string    `json:"booking_id"`
	AmountCents   int64     `json:"amount_cents"`
	Currency      string    `json:"currency"`
	Method        string    `json:"method"`
	Status        string    `json:"status"`
	Reference     string    `json:"reference"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// ChargeRequest is the POST /api/payments body sent by booking-service.
type ChargeRequest struct {
	BookingID   string `json:"booking_id"`
	AmountCents int64  `json:"amount_cents"`
	Currency    string `json:"currency"`
	Method      string `json:"method"`
}

// Validate reports the first problem with the charge request.
func (r *ChargeRequest) Validate() error {
	switch {
	case strings.TrimSpace(r.BookingID) == "":
		return errors.New("booking_id is required")
	case r.AmountCents <= 0:
		return errors.New("amount_cents must be greater than zero")
	case strings.TrimSpace(r.Method) == "":
		return errors.New("method is required")
	}
	return nil
}
