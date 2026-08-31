package id

import (
	"strings"
	"testing"
	"time"
)

func TestNewIsPrefixedAndFixedLength(t *testing.T) {
	got := New("evt")

	if !strings.HasPrefix(got, "evt_") {
		t.Fatalf("New(%q) = %q, want the prefix and an underscore", "evt", got)
	}

	// 16 bytes of base32 without padding is 26 characters.
	if suffix := strings.TrimPrefix(got, "evt_"); len(suffix) != 26 {
		t.Errorf("suffix %q has length %d, want 26", suffix, len(suffix))
	}
}

func TestNewWithoutPrefix(t *testing.T) {
	if got := New(""); strings.Contains(got, "_") {
		t.Errorf("New(\"\") = %q, want no separator when the prefix is empty", got)
	}
}

func TestNewIsUnique(t *testing.T) {
	const count = 100_000

	seen := make(map[string]struct{}, count)
	for i := 0; i < count; i++ {
		got := New("evt")
		if _, duplicate := seen[got]; duplicate {
			t.Fatalf("New produced the duplicate %q after %d calls", got, i)
		}
		seen[got] = struct{}{}
	}
}

// Identifiers are used as sort keys — payment-service and notification-service
// both order "newest first" by comparing them as plain strings — so lexical
// order has to track creation order.
func TestNewSortsChronologically(t *testing.T) {
	first := New("evt")
	time.Sleep(2 * time.Millisecond)
	second := New("evt")

	if !(first < second) {
		t.Errorf("expected %q to sort before %q", first, second)
	}
}

func TestNewIsConcurrencySafe(t *testing.T) {
	const goroutines = 50

	results := make(chan string, goroutines)
	for i := 0; i < goroutines; i++ {
		go func() { results <- New("evt") }()
	}

	seen := make(map[string]struct{}, goroutines)
	for i := 0; i < goroutines; i++ {
		got := <-results
		if _, duplicate := seen[got]; duplicate {
			t.Fatalf("concurrent New produced the duplicate %q", got)
		}
		seen[got] = struct{}{}
	}
}
