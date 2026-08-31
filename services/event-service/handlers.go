package main

import (
	"errors"
	"log/slog"
	"net/http"
	"time"

	"github.com/tirucloud/eventhub/internal/httpx"
	"github.com/tirucloud/eventhub/internal/id"
)

type api struct {
	store  Store
	logger *slog.Logger
}

// routes registers the event API. The patterns use the method-aware ServeMux
// added in Go 1.22, so there is no third-party router in this project.
func (a *api) routes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/events", a.listEvents)
	mux.HandleFunc("POST /api/events", a.createEvent)
	mux.HandleFunc("GET /api/events/{id}", a.getEvent)
	mux.HandleFunc("DELETE /api/events/{id}", a.deleteEvent)
	mux.HandleFunc("POST /api/events/{id}/reserve", a.reserveSeats)
	mux.HandleFunc("POST /api/events/{id}/release", a.releaseSeats)
}

func (a *api) listEvents(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter := ListFilter{
		City:     q.Get("city"),
		Category: q.Get("category"),
		Query:    q.Get("q"),
	}

	events, err := a.store.List(r.Context(), filter)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	httpx.JSON(w, http.StatusOK, map[string]any{
		"count":  len(events),
		"events": events,
	})
}

func (a *api) getEvent(w http.ResponseWriter, r *http.Request) {
	event, err := a.store.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusOK, event)
}

func (a *api) createEvent(w http.ResponseWriter, r *http.Request) {
	var req CreateEventRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.Error(w, http.StatusBadRequest, "validation_failed", err.Error())
		return
	}

	now := time.Now().UTC()
	currency := req.Currency
	if currency == "" {
		currency = "INR"
	}

	event := Event{
		ID:             id.New("evt"),
		Name:           req.Name,
		Description:    req.Description,
		Category:       req.Category,
		Venue:          req.Venue,
		City:           req.City,
		StartsAt:       req.StartsAt.UTC(),
		TotalSeats:     req.TotalSeats,
		AvailableSeats: req.TotalSeats,
		PriceCents:     req.PriceCents,
		Currency:       currency,
		CreatedAt:      now,
		UpdatedAt:      now,
	}

	created, err := a.store.Create(r.Context(), event)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	a.logger.Info("event created",
		slog.String("event_id", created.ID),
		slog.String("name", created.Name),
		slog.Int("total_seats", created.TotalSeats),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)
	httpx.JSON(w, http.StatusCreated, created)
}

func (a *api) deleteEvent(w http.ResponseWriter, r *http.Request) {
	if err := a.store.Delete(r.Context(), r.PathValue("id")); err != nil {
		a.fail(w, r, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// reserveSeats decrements availability. booking-service calls this first, and
// only charges the customer once it succeeds.
func (a *api) reserveSeats(w http.ResponseWriter, r *http.Request) {
	a.adjust(w, r, -1)
}

// releaseSeats increments availability. It is the compensating action the
// booking saga runs when payment is declined or a booking is cancelled.
func (a *api) releaseSeats(w http.ResponseWriter, r *http.Request) {
	a.adjust(w, r, 1)
}

func (a *api) adjust(w http.ResponseWriter, r *http.Request, sign int) {
	var req SeatsRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.Error(w, http.StatusBadRequest, "validation_failed", err.Error())
		return
	}

	eventID := r.PathValue("id")
	event, err := a.store.AdjustSeats(r.Context(), eventID, sign*req.Seats)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	action := "reserved"
	if sign > 0 {
		action = "released"
	}
	a.logger.Info("seats "+action,
		slog.String("event_id", eventID),
		slog.Int("seats", req.Seats),
		slog.Int("available_seats", event.AvailableSeats),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)
	httpx.JSON(w, http.StatusOK, event)
}

// fail maps store errors onto HTTP status codes in one place, so every handler
// reports the same problem the same way.
func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	switch {
	case errors.Is(err, ErrNotFound):
		httpx.Error(w, http.StatusNotFound, "event_not_found", "no event with that id")
	case errors.Is(err, ErrInsufficientSeats):
		httpx.Error(w, http.StatusConflict, "insufficient_seats", "not enough seats remaining")
	case errors.Is(err, ErrTooManySeats):
		httpx.Error(w, http.StatusConflict, "release_exceeds_capacity", "release would exceed total capacity")
	default:
		a.logger.Error("request failed",
			slog.Any("error", err),
			slog.String("path", r.URL.Path),
			slog.String("request_id", httpx.RequestIDFrom(r.Context())),
		)
		httpx.Error(w, http.StatusInternalServerError, "internal_error", "unexpected server error")
	}
}
