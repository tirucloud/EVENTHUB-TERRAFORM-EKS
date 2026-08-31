package main

import (
	"context"
	"errors"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/tirucloud/eventhub/internal/id"
)

var (
	// ErrNotFound means no event exists with the requested identifier.
	ErrNotFound = errors.New("event not found")
	// ErrInsufficientSeats means the reservation asked for more seats than remain.
	ErrInsufficientSeats = errors.New("insufficient seats available")
	// ErrTooManySeats means a release would push availability past capacity,
	// which indicates a double-release bug in the caller.
	ErrTooManySeats = errors.New("release exceeds total capacity")
)

// Store is the persistence contract. Two implementations exist: memoryStore for
// local runs and postgresStore for the cluster. Swapping between them is a
// single environment variable, which keeps the Terraform demo honest without
// forcing a database on anyone running `docker compose up`.
type Store interface {
	List(ctx context.Context, f ListFilter) ([]Event, error)
	Get(ctx context.Context, eventID string) (Event, error)
	Create(ctx context.Context, e Event) (Event, error)
	Delete(ctx context.Context, eventID string) error
	// AdjustSeats atomically applies delta to available_seats. A negative delta
	// reserves, a positive delta releases. It must never let availability fall
	// below zero or rise above total_seats.
	AdjustSeats(ctx context.Context, eventID string, delta int) (Event, error)
	Ping(ctx context.Context) error
	Close()
}

// memoryStore keeps events in a map guarded by a mutex.
type memoryStore struct {
	mu     sync.RWMutex
	events map[string]Event
}

func newMemoryStore() *memoryStore {
	return &memoryStore{events: make(map[string]Event)}
}

func (s *memoryStore) List(_ context.Context, f ListFilter) ([]Event, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	out := make([]Event, 0, len(s.events))
	for _, e := range s.events {
		if matches(e, f) {
			out = append(out, e)
		}
	}
	sortEvents(out)
	return out, nil
}

func (s *memoryStore) Get(_ context.Context, eventID string) (Event, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()

	e, ok := s.events[eventID]
	if !ok {
		return Event{}, ErrNotFound
	}
	return e, nil
}

func (s *memoryStore) Create(_ context.Context, e Event) (Event, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	s.events[e.ID] = e
	return e, nil
}

func (s *memoryStore) Delete(_ context.Context, eventID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if _, ok := s.events[eventID]; !ok {
		return ErrNotFound
	}
	delete(s.events, eventID)
	return nil
}

func (s *memoryStore) AdjustSeats(_ context.Context, eventID string, delta int) (Event, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	e, ok := s.events[eventID]
	if !ok {
		return Event{}, ErrNotFound
	}

	next := e.AvailableSeats + delta
	switch {
	case next < 0:
		return Event{}, ErrInsufficientSeats
	case next > e.TotalSeats:
		return Event{}, ErrTooManySeats
	}

	e.AvailableSeats = next
	e.UpdatedAt = time.Now().UTC()
	s.events[eventID] = e
	return e, nil
}

func (s *memoryStore) Ping(context.Context) error { return nil }

func (s *memoryStore) Close() {}

func matches(e Event, f ListFilter) bool {
	if f.City != "" && !strings.EqualFold(e.City, f.City) {
		return false
	}
	if f.Category != "" && !strings.EqualFold(e.Category, f.Category) {
		return false
	}
	if f.Query != "" {
		q := strings.ToLower(f.Query)
		if !strings.Contains(strings.ToLower(e.Name), q) &&
			!strings.Contains(strings.ToLower(e.Description), q) &&
			!strings.Contains(strings.ToLower(e.Venue), q) {
			return false
		}
	}
	return true
}

// sortEvents orders by start time so the frontend always renders the next event
// first, with the identifier as a tiebreaker for a stable order.
func sortEvents(events []Event) {
	sort.Slice(events, func(i, j int) bool {
		if events[i].StartsAt.Equal(events[j].StartsAt) {
			return events[i].ID < events[j].ID
		}
		return events[i].StartsAt.Before(events[j].StartsAt)
	})
}

// seedEvents is the demo catalogue loaded when the store starts out empty.
func seedEvents() []Event {
	now := time.Now().UTC()
	base := []struct {
		name, desc, category, venue, city string
		inDays                            int
		seats                             int
		price                             int64
	}{
		{"Hyderabad Tech Summit", "A full day on platform engineering, Kubernetes and everything in between.", "conference", "HITEX Exhibition Centre", "Hyderabad", 14, 500, 249900},
		{"Sunburn Arena", "Electronic music headliners across two stages.", "music", "Gachibowli Stadium", "Hyderabad", 21, 2000, 349900},
		{"Cloud Native Bootcamp", "Hands-on Terraform and EKS workshop, laptops required.", "workshop", "T-Hub Phase 2", "Hyderabad", 7, 60, 129900},
		{"Bengaluru Marathon", "Timed 10K and half-marathon through Cubbon Park.", "sports", "Kanteerava Stadium", "Bengaluru", 30, 5000, 89900},
		{"Standup Night Live", "Three comedians, one microphone, no script.", "comedy", "Phoenix Marketcity", "Mumbai", 10, 300, 79900},
		{"Indie Film Premiere", "Screening followed by a director Q&A.", "film", "PVR Forum Mall", "Chennai", 5, 180, 59900},
	}

	out := make([]Event, 0, len(base))
	for _, b := range base {
		out = append(out, Event{
			ID:             id.New("evt"),
			Name:           b.name,
			Description:    b.desc,
			Category:       b.category,
			Venue:          b.venue,
			City:           b.city,
			StartsAt:       now.AddDate(0, 0, b.inDays).Truncate(time.Hour),
			TotalSeats:     b.seats,
			AvailableSeats: b.seats,
			PriceCents:     b.price,
			Currency:       "INR",
			CreatedAt:      now,
			UpdatedAt:      now,
		})
	}
	return out
}
