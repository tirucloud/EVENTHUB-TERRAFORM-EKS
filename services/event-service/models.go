package main

import (
	"errors"
	"fmt"
	"strings"
	"time"
)

// Event is a bookable event. Seat inventory lives here and nowhere else:
// booking-service must call this service to reserve or release seats, which is
// what makes the two services genuinely independent.
type Event struct {
	ID             string    `json:"id"`
	Name           string    `json:"name"`
	Description    string    `json:"description"`
	Category       string    `json:"category"`
	Venue          string    `json:"venue"`
	City           string    `json:"city"`
	StartsAt       time.Time `json:"starts_at"`
	TotalSeats     int       `json:"total_seats"`
	AvailableSeats int       `json:"available_seats"`
	PriceCents     int64     `json:"price_cents"`
	Currency       string    `json:"currency"`
	CreatedAt      time.Time `json:"created_at"`
	UpdatedAt      time.Time `json:"updated_at"`
}

// CreateEventRequest is the POST /api/events body.
type CreateEventRequest struct {
	Name        string    `json:"name"`
	Description string    `json:"description"`
	Category    string    `json:"category"`
	Venue       string    `json:"venue"`
	City        string    `json:"city"`
	StartsAt    time.Time `json:"starts_at"`
	TotalSeats  int       `json:"total_seats"`
	PriceCents  int64     `json:"price_cents"`
	Currency    string    `json:"currency"`
}

// Validate reports the first problem with the request, or nil when it is sound.
func (r *CreateEventRequest) Validate() error {
	switch {
	case strings.TrimSpace(r.Name) == "":
		return errors.New("name is required")
	case strings.TrimSpace(r.Venue) == "":
		return errors.New("venue is required")
	case r.TotalSeats <= 0:
		return errors.New("total_seats must be greater than zero")
	case r.TotalSeats > 1_000_000:
		return errors.New("total_seats must be at most 1000000")
	case r.PriceCents < 0:
		return errors.New("price_cents cannot be negative")
	case r.StartsAt.IsZero():
		return errors.New("starts_at is required")
	}
	return nil
}

// SeatsRequest is the body of the reserve and release endpoints.
type SeatsRequest struct {
	Seats int `json:"seats"`
}

// Validate keeps a single request from draining an entire venue by accident.
func (r *SeatsRequest) Validate() error {
	if r.Seats <= 0 {
		return errors.New("seats must be greater than zero")
	}
	if r.Seats > maxSeatsPerRequest {
		return fmt.Errorf("seats must be at most %d", maxSeatsPerRequest)
	}
	return nil
}

const maxSeatsPerRequest = 10

// ListFilter narrows GET /api/events.
type ListFilter struct {
	City     string
	Category string
	Query    string
}
