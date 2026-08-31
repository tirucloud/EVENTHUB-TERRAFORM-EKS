package main

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

var (
	// ErrNotFound means no booking exists with the requested identifier.
	ErrNotFound = errors.New("booking not found")
	// ErrNotCancellable means the booking is not in a state that can be cancelled.
	ErrNotCancellable = errors.New("booking is not cancellable")
)

// Store persists bookings.
type Store interface {
	Create(ctx context.Context, b Booking) (Booking, error)
	Get(ctx context.Context, bookingID string) (Booking, error)
	List(ctx context.Context, email string, limit int) ([]Booking, error)
	// UpdateStatus moves a booking to a new status, but only from one of the
	// allowed current states. It returns ErrNotCancellable when the transition
	// is not permitted, which is how duplicate cancellations are rejected.
	UpdateStatus(ctx context.Context, bookingID, status string, allowedFrom []string, paymentID, failureReason string) (Booking, error)
	Ping(ctx context.Context) error
	Close()
}

type memoryStore struct {
	mu       sync.RWMutex
	bookings map[string]Booking
}

func newMemoryStore() *memoryStore {
	return &memoryStore{bookings: make(map[string]Booking)}
}

func (s *memoryStore) Create(_ context.Context, b Booking) (Booking, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.bookings[b.ID] = b
	return b, nil
}

func (s *memoryStore) Get(_ context.Context, bookingID string) (Booking, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	b, ok := s.bookings[bookingID]
	if !ok {
		return Booking{}, ErrNotFound
	}
	return b, nil
}

func (s *memoryStore) List(_ context.Context, email string, limit int) ([]Booking, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Booking, 0, len(s.bookings))
	for _, b := range s.bookings {
		if email == "" || b.CustomerEmail == email {
			out = append(out, b)
		}
	}

	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })

	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *memoryStore) UpdateStatus(_ context.Context, bookingID, status string, allowedFrom []string, paymentID, failureReason string) (Booking, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	b, ok := s.bookings[bookingID]
	if !ok {
		return Booking{}, ErrNotFound
	}
	if !contains(allowedFrom, b.Status) {
		return Booking{}, ErrNotCancellable
	}

	b.Status = status
	if paymentID != "" {
		b.PaymentID = paymentID
	}
	if failureReason != "" {
		b.FailureReason = failureReason
	}
	b.UpdatedAt = time.Now().UTC()

	s.bookings[bookingID] = b
	return b, nil
}

func (s *memoryStore) Ping(context.Context) error { return nil }

func (s *memoryStore) Close() {}

func contains(values []string, target string) bool {
	for _, v := range values {
		if v == target {
			return true
		}
	}
	return false
}
