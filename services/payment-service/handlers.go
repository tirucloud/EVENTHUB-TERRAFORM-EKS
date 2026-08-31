package main

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/vijaygiduthuri/eventhub/internal/httpx"
	"github.com/vijaygiduthuri/eventhub/internal/id"
)

type api struct {
	store   Store
	gateway *gateway
	logger  *slog.Logger
}

func (a *api) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/payments", a.charge)
	mux.HandleFunc("GET /api/payments", a.listPayments)
	mux.HandleFunc("GET /api/payments/{id}", a.getPayment)
	mux.HandleFunc("POST /api/payments/{id}/refund", a.refund)
}

// charge runs the mock gateway and records the outcome.
//
// A declined card is a business outcome, not a server fault, so it answers 402
// Payment Required with a persisted DECLINED record rather than a 5xx. That
// distinction is what lets booking-service compensate instead of retry.
func (a *api) charge(w http.ResponseWriter, r *http.Request) {
	var req ChargeRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.Error(w, http.StatusBadRequest, "validation_failed", err.Error())
		return
	}

	currency := req.Currency
	if currency == "" {
		currency = "INR"
	}

	now := time.Now().UTC()
	payment := Payment{
		ID:          id.New("pay"),
		BookingID:   req.BookingID,
		AmountCents: req.AmountCents,
		Currency:    currency,
		Method:      strings.ToLower(req.Method),
		Reference:   id.New("ref"),
		CreatedAt:   now,
		UpdatedAt:   now,
	}

	verdict := a.gateway.authorize(req)
	if verdict.authorized {
		payment.Status = StatusAuthorized
	} else {
		payment.Status = StatusDeclined
		payment.FailureReason = verdict.reason
	}

	stored, err := a.store.Create(r.Context(), payment)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	a.logger.Info("payment processed",
		slog.String("payment_id", stored.ID),
		slog.String("booking_id", stored.BookingID),
		slog.String("status", stored.Status),
		slog.Int64("amount_cents", stored.AmountCents),
		slog.String("failure_reason", stored.FailureReason),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)

	if stored.Status == StatusDeclined {
		httpx.JSON(w, http.StatusPaymentRequired, stored)
		return
	}
	httpx.JSON(w, http.StatusCreated, stored)
}

func (a *api) getPayment(w http.ResponseWriter, r *http.Request) {
	payment, err := a.store.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusOK, payment)
}

func (a *api) listPayments(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	payments, err := a.store.List(r.Context(), r.URL.Query().Get("booking_id"), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	httpx.JSON(w, http.StatusOK, map[string]any{
		"count":    len(payments),
		"payments": payments,
	})
}

// refund is the compensating action booking-service calls when a confirmed
// booking is cancelled.
func (a *api) refund(w http.ResponseWriter, r *http.Request) {
	payment, err := a.store.Refund(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}

	a.logger.Info("payment refunded",
		slog.String("payment_id", payment.ID),
		slog.String("booking_id", payment.BookingID),
		slog.Int64("amount_cents", payment.AmountCents),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)
	httpx.JSON(w, http.StatusOK, payment)
}

func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.Error(w, http.StatusNotFound, "payment_not_found", "no payment with that id")
	case errors.Is(err, ErrNotRefundable):
		httpx.Error(w, http.StatusConflict, "not_refundable", "only authorized payments can be refunded")
	default:
		a.logger.Error("request failed",
			slog.Any("error", err),
			slog.String("path", r.URL.Path),
			slog.String("request_id", httpx.RequestIDFrom(r.Context())),
		)
		httpx.Error(w, http.StatusInternalServerError, "internal_error", "unexpected server error")
	}
}
