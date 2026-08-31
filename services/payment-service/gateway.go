package main

import (
	"math/rand"
	"strings"
	"time"

	"github.com/vijaygiduthuri/eventhub/internal/config"
)

// gateway stands in for a real payment processor.
//
// Every decision it makes is deliberately reproducible so the session can
// demonstrate the failure path on demand: pay with the method "declined-card"
// and the booking saga will roll the seat reservation back in front of the
// audience. FailureRate exists for the opposite demo — turn it up and watch
// retries and error rates move.
type gateway struct {
	maxAmountCents int64
	failureRate    float64
	latency        time.Duration
	rng            *rand.Rand
}

func newGateway() *gateway {
	return &gateway{
		// Default ceiling is 50,000.00 in minor units.
		maxAmountCents: int64(config.Int("MAX_AMOUNT_CENTS", 5_000_000)),
		failureRate:    float64(config.Int("FAILURE_RATE_PERCENT", 0)) / 100,
		latency:        config.Duration("GATEWAY_LATENCY", 120*time.Millisecond),
		rng:            rand.New(rand.NewSource(time.Now().UnixNano())),
	}
}

// decision is the gateway verdict for one charge attempt.
type decision struct {
	authorized bool
	reason     string
}

// authorize applies the mock rules in priority order.
func (g *gateway) authorize(req ChargeRequest) decision {
	// Simulated network round-trip to the processor, so latency shows up in the
	// booking flow and in the access logs.
	if g.latency > 0 {
		time.Sleep(g.latency)
	}

	if strings.EqualFold(req.Method, "declined-card") {
		return decision{reason: "card_declined"}
	}
	if req.AmountCents > g.maxAmountCents {
		return decision{reason: "amount_limit_exceeded"}
	}
	if g.failureRate > 0 && g.rng.Float64() < g.failureRate {
		return decision{reason: "issuer_unavailable"}
	}
	return decision{authorized: true}
}
