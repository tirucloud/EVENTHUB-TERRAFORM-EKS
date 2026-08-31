package main

import (
	"errors"
	"strings"
	"time"
)

// Delivery channels supported by the mock dispatcher.
const (
	ChannelEmail = "email"
	ChannelSMS   = "sms"
	ChannelPush  = "push"
)

// Delivery outcomes.
const (
	StatusSent   = "SENT"
	StatusFailed = "FAILED"
)

// Notification is one message EventHub tried to deliver to a customer.
type Notification struct {
	ID        string    `json:"id"`
	Channel   string    `json:"channel"`
	Recipient string    `json:"recipient"`
	Subject   string    `json:"subject"`
	Body      string    `json:"body"`
	BookingID string    `json:"booking_id,omitempty"`
	EventID   string    `json:"event_id,omitempty"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

// SendRequest is the POST /api/notifications body.
type SendRequest struct {
	Channel   string `json:"channel"`
	Recipient string `json:"recipient"`
	Subject   string `json:"subject"`
	Body      string `json:"body"`
	BookingID string `json:"booking_id"`
	EventID   string `json:"event_id"`
}

// Validate reports the first problem with the request and normalises nothing;
// normalisation happens in the handler so the caller sees exactly what it sent.
func (r *SendRequest) Validate() error {
	switch {
	case strings.TrimSpace(r.Recipient) == "":
		return errors.New("recipient is required")
	case strings.TrimSpace(r.Subject) == "":
		return errors.New("subject is required")
	case len(r.Body) > 4000:
		return errors.New("body must be at most 4000 characters")
	}

	switch strings.ToLower(strings.TrimSpace(r.Channel)) {
	case "", ChannelEmail, ChannelSMS, ChannelPush:
		return nil
	default:
		return errors.New("channel must be one of email, sms, push")
	}
}
