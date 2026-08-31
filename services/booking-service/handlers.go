package main

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"

	"github.com/tirucloud/eventhub/internal/httpx"
)

type api struct {
	store        Store
	orchestrator *orchestrator
	logger       *slog.Logger
}

func (a *api) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/bookings", a.createBooking)
	mux.HandleFunc("GET /api/bookings", a.listBookings)
	mux.HandleFunc("GET /api/bookings/{id}", a.getBooking)
	mux.HandleFunc("POST /api/bookings/{id}/cancel", a.cancelBooking)
}

func (a *api) createBooking(w http.ResponseWriter, r *http.Request) {
	var req CreateBookingRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.Error(w, http.StatusBadRequest, "validation_failed", err.Error())
		return
	}

	booking, err := a.orchestrator.Book(r.Context(), req)
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusCreated, booking)
}

func (a *api) getBooking(w http.ResponseWriter, r *http.Request) {
	booking, err := a.store.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusOK, booking)
}

func (a *api) listBookings(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	bookings, err := a.store.List(r.Context(), r.URL.Query().Get("email"), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	httpx.JSON(w, http.StatusOK, map[string]any{
		"count":    len(bookings),
		"bookings": bookings,
	})
}

func (a *api) cancelBooking(w http.ResponseWriter, r *http.Request) {
	booking, err := a.orchestrator.Cancel(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusOK, booking)
}

// fail translates saga and store errors into HTTP responses.
func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	var be *bookingError
	if errors.As(err, &be) {
		httpx.Error(w, be.status, be.code, be.message)
		return
	}

	switch {
	case errors.Is(err, ErrNotFound):
		httpx.Error(w, http.StatusNotFound, "booking_not_found", "no booking with that id")
	case errors.Is(err, ErrNotCancellable):
		httpx.Error(w, http.StatusConflict, "not_cancellable", "only confirmed bookings can be cancelled")
	default:
		a.logger.Error("request failed",
			slog.Any("error", err),
			slog.String("path", r.URL.Path),
			slog.String("request_id", httpx.RequestIDFrom(r.Context())),
		)
		httpx.Error(w, http.StatusInternalServerError, "internal_error", "unexpected server error")
	}
}
