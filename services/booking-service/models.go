package main

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Booking lifecycle. A booking starts PENDING, then moves exactly once to
// CONFIRMED or FAILED. Only a CONFIRMED booking can later become CANCELLED.
const (
	StatusPending   = "PENDING"
	StatusConfirmed = "CONFIRMED"
	StatusFailed    = "FAILED"
	StatusCancelled = "CANCELLED"
)

const maxSeatsPerBooking = 10

// Booking is a customer's reservation for an event.
type Booking struct {
	ID            string    `json:"id"`
	EventID       string    `json:"event_id"`
	EventName     string    `json:"event_name"`
	CustomerName  string    `json:"customer_name"`
	CustomerEmail string    `json:"customer_email"`
	Seats         int       `json:"seats"`
	AmountCents   int64     `json:"amount_cents"`
	Currency      string    `json:"currency"`
	Status        string    `json:"status"`
	PaymentID     string    `json:"payment_id,omitempty"`
	FailureReason string    `json:"failure_reason,omitempty"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// CreateBookingRequest is the POST /api/bookings body.
type CreateBookingRequest struct {
	EventID       string `json:"event_id"`
	Seats         int    `json:"seats"`
	CustomerName  string `json:"customer_name"`
	CustomerEmail string `json:"customer_email"`
	PaymentMethod string `json:"payment_method"`
}

// Validate reports the first problem with the booking request.
func (r *CreateBookingRequest) Validate() error {
	switch {
	case strings.TrimSpace(r.EventID) == "":
		return errors.New("event_id is required")
	case r.Seats <= 0:
		return errors.New("seats must be greater than zero")
	case r.Seats > maxSeatsPerBooking:
		return fmt.Errorf("seats must be at most %d", maxSeatsPerBooking)
	case strings.TrimSpace(r.CustomerName) == "":
		return errors.New("customer_name is required")
	case !strings.Contains(r.CustomerEmail, "@"):
		return errors.New("customer_email must be a valid email address")
	}
	return nil
}

// Method returns the payment method, defaulting to a card.
func (r *CreateBookingRequest) Method() string {
	if m := strings.TrimSpace(r.PaymentMethod); m != "" {
		return strings.ToLower(m)
	}
	return "card"
}

// remoteEvent is the subset of event-service's response that booking-service
// needs. Deliberately partial: a downstream service is free to add fields
// without breaking this one.
type remoteEvent struct {
	ID             string `json:"id"`
	Name           string `json:"name"`
	AvailableSeats int    `json:"available_seats"`
	PriceCents     int64  `json:"price_cents"`
	Currency       string `json:"currency"`
}

// remotePayment is the subset of payment-service's response we care about.
type remotePayment struct {
	ID            string `json:"id"`
	Status        string `json:"status"`
	FailureReason string `json:"failure_reason"`
}
