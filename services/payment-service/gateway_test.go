package main

import (
	"math/rand"
	"testing"
	"time"
)

func testGateway() *gateway {
	return &gateway{
		maxAmountCents: 5_000_000,
		failureRate:    0,
		latency:        0, // keep the tests fast
		rng:            rand.New(rand.NewSource(1)),
	}
}

func TestAuthorizeApprovesOrdinaryCharge(t *testing.T) {
	got := testGateway().authorize(ChargeRequest{
		BookingID:   "bkg_1",
		AmountCents: 249900,
		Method:      "card",
	})

	if !got.authorized {
		t.Errorf("authorize declined a valid charge with reason %q", got.reason)
	}
}

// The demo hinge: this method must always decline, so the booking saga's
// compensation path can be shown on demand.
func TestAuthorizeAlwaysDeclinesTheDemoCard(t *testing.T) {
	g := testGateway()

	for _, method := range []string{"declined-card", "DECLINED-CARD", "Declined-Card"} {
		got := g.authorize(ChargeRequest{AmountCents: 100, Method: method})

		if got.authorized {
			t.Errorf("authorize(%q) was approved, want a decline", method)
		}
		if got.reason != "card_declined" {
			t.Errorf("authorize(%q) reason = %q, want card_declined", method, got.reason)
		}
	}
}

func TestAuthorizeEnforcesAmountCeiling(t *testing.T) {
	g := testGateway()

	if got := g.authorize(ChargeRequest{AmountCents: g.maxAmountCents, Method: "card"}); !got.authorized {
		t.Errorf("a charge exactly at the ceiling was declined with %q", got.reason)
	}

	got := g.authorize(ChargeRequest{AmountCents: g.maxAmountCents + 1, Method: "card"})
	if got.authorized {
		t.Fatal("a charge over the ceiling was approved")
	}
	if got.reason != "amount_limit_exceeded" {
		t.Errorf("reason = %q, want amount_limit_exceeded", got.reason)
	}
}

// The card rule is checked before the amount rule, so a declining card reports
// the reason the operator chose rather than an incidental one.
func TestDeclinedCardTakesPrecedenceOverAmount(t *testing.T) {
	g := testGateway()

	got := g.authorize(ChargeRequest{AmountCents: g.maxAmountCents + 1, Method: "declined-card"})
	if got.reason != "card_declined" {
		t.Errorf("reason = %q, want card_declined to win", got.reason)
	}
}

func TestFailureRateDeclinesEverythingAtOneHundredPercent(t *testing.T) {
	g := testGateway()
	g.failureRate = 1

	for i := 0; i < 20; i++ {
		got := g.authorize(ChargeRequest{AmountCents: 100, Method: "card"})
		if got.authorized {
			t.Fatal("a charge was approved with failureRate at 1.0")
		}
		if got.reason != "issuer_unavailable" {
			t.Errorf("reason = %q, want issuer_unavailable", got.reason)
		}
	}
}

func TestValidateRejectsBadRequests(t *testing.T) {
	tests := map[string]ChargeRequest{
		"missing booking id": {AmountCents: 100, Method: "card"},
		"zero amount":        {BookingID: "bkg_1", AmountCents: 0, Method: "card"},
		"negative amount":    {BookingID: "bkg_1", AmountCents: -100, Method: "card"},
		"missing method":     {BookingID: "bkg_1", AmountCents: 100},
	}

	for name, req := range tests {
		t.Run(name, func(t *testing.T) {
			if err := req.Validate(); err == nil {
				t.Errorf("Validate() accepted %+v", req)
			}
		})
	}
}

func TestValidateAcceptsAGoodRequest(t *testing.T) {
	req := ChargeRequest{BookingID: "bkg_1", AmountCents: 249900, Method: "upi"}

	if err := req.Validate(); err != nil {
		t.Errorf("Validate() = %v, want nil", err)
	}
}

func TestGatewayLatencyIsApplied(t *testing.T) {
	g := testGateway()
	g.latency = 20 * time.Millisecond

	start := time.Now()
	g.authorize(ChargeRequest{AmountCents: 100, Method: "card"})

	if elapsed := time.Since(start); elapsed < g.latency {
		t.Errorf("authorize returned after %s, want at least the configured %s", elapsed, g.latency)
	}
}
