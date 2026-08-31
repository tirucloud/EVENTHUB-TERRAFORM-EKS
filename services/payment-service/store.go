package main

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

var (
	// ErrNotFound means no payment exists with the requested identifier.
	ErrNotFound = errors.New("payment not found")
	// ErrNotRefundable means the payment was never authorised, or was already
	// refunded, so there is nothing to give back.
	ErrNotRefundable = errors.New("payment is not refundable")
)

// Store persists payment records.
type Store interface {
	Create(ctx context.Context, p Payment) (Payment, error)
	Get(ctx context.Context, paymentID string) (Payment, error)
	List(ctx context.Context, bookingID string, limit int) ([]Payment, error)
	// Refund flips an authorised payment to REFUNDED and returns the updated row.
	Refund(ctx context.Context, paymentID string) (Payment, error)
	Ping(ctx context.Context) error
	Close()
}

type memoryStore struct {
	mu       sync.RWMutex
	payments map[string]Payment
}

func newMemoryStore() *memoryStore {
	return &memoryStore{payments: make(map[string]Payment)}
}

func (s *memoryStore) Create(_ context.Context, p Payment) (Payment, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.payments[p.ID] = p
	return p, nil
}

func (s *memoryStore) Get(_ context.Context, paymentID string) (Payment, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	p, ok := s.payments[paymentID]
	if !ok {
		return Payment{}, ErrNotFound
	}
	return p, nil
}

func (s *memoryStore) List(_ context.Context, bookingID string, limit int) ([]Payment, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Payment, 0, len(s.payments))
	for _, p := range s.payments {
		if bookingID == "" || p.BookingID == bookingID {
			out = append(out, p)
		}
	}

	// Newest first; identifiers are time-ordered so this is a plain reverse sort.
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })

	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *memoryStore) Refund(_ context.Context, paymentID string) (Payment, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	p, ok := s.payments[paymentID]
	if !ok {
		return Payment{}, ErrNotFound
	}
	if p.Status != StatusAuthorized {
		return Payment{}, ErrNotRefundable
	}

	p.Status = StatusRefunded
	p.UpdatedAt = time.Now().UTC()
	s.payments[paymentID] = p
	return p, nil
}

func (s *memoryStore) Ping(context.Context) error { return nil }

func (s *memoryStore) Close() {}
