package main

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"

	"github.com/tirucloud/eventhub/internal/id"
)

func testEvent(seats int) Event {
	now := time.Now().UTC()
	return Event{
		ID:             id.New("evt"),
		Name:           "Cloud Native Bootcamp",
		Venue:          "T-Hub",
		City:           "Hyderabad",
		Category:       "workshop",
		StartsAt:       now.AddDate(0, 0, 7),
		TotalSeats:     seats,
		AvailableSeats: seats,
		PriceCents:     129900,
		Currency:       "INR",
		CreatedAt:      now,
		UpdatedAt:      now,
	}
}

func TestAdjustSeatsReserves(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore()

	event, err := store.Create(ctx, testEvent(10))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := store.AdjustSeats(ctx, event.ID, -3)
	if err != nil {
		t.Fatalf("AdjustSeats: %v", err)
	}

	if got.AvailableSeats != 7 {
		t.Errorf("AvailableSeats = %d, want 7", got.AvailableSeats)
	}
	if got.TotalSeats != 10 {
		t.Errorf("TotalSeats = %d, want it left alone at 10", got.TotalSeats)
	}
}

func TestAdjustSeatsRejectsOverselling(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore()

	event, _ := store.Create(ctx, testEvent(2))

	if _, err := store.AdjustSeats(ctx, event.ID, -3); !errors.Is(err, ErrInsufficientSeats) {
		t.Fatalf("AdjustSeats(-3) error = %v, want ErrInsufficientSeats", err)
	}

	// The rejected reservation must not have changed anything.
	after, _ := store.Get(ctx, event.ID)
	if after.AvailableSeats != 2 {
		t.Errorf("AvailableSeats = %d after a rejected reservation, want 2", after.AvailableSeats)
	}
}

func TestAdjustSeatsRejectsReleaseBeyondCapacity(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore()

	event, _ := store.Create(ctx, testEvent(5))

	// Guards against a double-release bug in the booking saga inventing seats
	// that never existed.
	if _, err := store.AdjustSeats(ctx, event.ID, 1); !errors.Is(err, ErrTooManySeats) {
		t.Fatalf("AdjustSeats(+1) on a full event = %v, want ErrTooManySeats", err)
	}
}

func TestAdjustSeatsUnknownEvent(t *testing.T) {
	store := newMemoryStore()

	if _, err := store.AdjustSeats(context.Background(), "evt_missing", -1); !errors.Is(err, ErrNotFound) {
		t.Fatalf("AdjustSeats on a missing event = %v, want ErrNotFound", err)
	}
}

// The property that actually matters: however many people press Book at once,
// the number of seats sold never exceeds the number of seats that exist.
func TestAdjustSeatsIsRaceFree(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore()

	const (
		capacity = 50
		bookers  = 200
	)

	event, _ := store.Create(ctx, testEvent(capacity))

	var (
		wg        sync.WaitGroup
		mu        sync.Mutex
		succeeded int
	)

	for i := 0; i < bookers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()

			if _, err := store.AdjustSeats(ctx, event.ID, -1); err == nil {
				mu.Lock()
				succeeded++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()

	if succeeded != capacity {
		t.Errorf("%d reservations succeeded, want exactly %d", succeeded, capacity)
	}

	final, _ := store.Get(ctx, event.ID)
	if final.AvailableSeats != 0 {
		t.Errorf("AvailableSeats = %d, want 0", final.AvailableSeats)
	}
}

func TestListFiltersByCity(t *testing.T) {
	ctx := context.Background()
	store := newMemoryStore()

	hyderabad := testEvent(10)
	mumbai := testEvent(10)
	mumbai.City = "Mumbai"

	if _, err := store.Create(ctx, hyderabad); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if _, err := store.Create(ctx, mumbai); err != nil {
		t.Fatalf("Create: %v", err)
	}

	got, err := store.List(ctx, ListFilter{City: "mumbai"}) // deliberately lowercase
	if err != nil {
		t.Fatalf("List: %v", err)
	}

	if len(got) != 1 || got[0].City != "Mumbai" {
		t.Errorf("List returned %d events %v, want just the Mumbai one", len(got), got)
	}
}

func TestSeedEventsAreConsistent(t *testing.T) {
	for _, event := range seedEvents() {
		if event.AvailableSeats != event.TotalSeats {
			t.Errorf("%s: AvailableSeats %d != TotalSeats %d",
				event.Name, event.AvailableSeats, event.TotalSeats)
		}
		if event.StartsAt.Before(time.Now()) {
			t.Errorf("%s: starts in the past at %s", event.Name, event.StartsAt)
		}
		if event.PriceCents <= 0 {
			t.Errorf("%s: PriceCents = %d, want a positive price", event.Name, event.PriceCents)
		}
	}
}
