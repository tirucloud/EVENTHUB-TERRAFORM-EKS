package main

import (
	"context"
	"errors"
	"sort"
	"sync"
)

// ErrNotFound means no notification exists with the requested identifier.
var ErrNotFound = errors.New("notification not found")

// Store persists the delivery log.
type Store interface {
	Create(ctx context.Context, n Notification) (Notification, error)
	Get(ctx context.Context, notificationID string) (Notification, error)
	List(ctx context.Context, bookingID string, limit int) ([]Notification, error)
	Ping(ctx context.Context) error
	Close()
}

// memoryStore keeps the most recent notifications in a bounded ring so a demo
// left running overnight cannot exhaust the pod's memory limit.
type memoryStore struct {
	mu            sync.RWMutex
	notifications map[string]Notification
	order         []string
	max           int
}

func newMemoryStore(max int) *memoryStore {
	if max <= 0 {
		max = 500
	}
	return &memoryStore{
		notifications: make(map[string]Notification),
		order:         make([]string, 0, max),
		max:           max,
	}
}

func (s *memoryStore) Create(_ context.Context, n Notification) (Notification, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.notifications[n.ID] = n
	s.order = append(s.order, n.ID)

	// Evict oldest entries once the ring is full.
	for len(s.order) > s.max {
		oldest := s.order[0]
		s.order = s.order[1:]
		delete(s.notifications, oldest)
	}
	return n, nil
}

func (s *memoryStore) Get(_ context.Context, notificationID string) (Notification, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	n, ok := s.notifications[notificationID]
	if !ok {
		return Notification{}, ErrNotFound
	}
	return n, nil
}

func (s *memoryStore) List(_ context.Context, bookingID string, limit int) ([]Notification, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Notification, 0, len(s.notifications))
	for _, n := range s.notifications {
		if bookingID == "" || n.BookingID == bookingID {
			out = append(out, n)
		}
	}

	// Identifiers are timestamp-prefixed, so descending order is newest first.
	sort.Slice(out, func(i, j int) bool { return out[i].ID > out[j].ID })

	if limit > 0 && len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

func (s *memoryStore) Ping(context.Context) error { return nil }

func (s *memoryStore) Close() {}
