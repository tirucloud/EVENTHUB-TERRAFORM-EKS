package main

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/tirucloud/eventhub/internal/httpx"
	"github.com/tirucloud/eventhub/internal/id"
)

type api struct {
	store  Store
	logger *slog.Logger
}

func (a *api) routes(mux *http.ServeMux) {
	mux.HandleFunc("POST /api/notifications", a.send)
	mux.HandleFunc("GET /api/notifications", a.listNotifications)
	mux.HandleFunc("GET /api/notifications/{id}", a.getNotification)
}

// send records a delivery attempt. There is no real SMTP or SMS provider here:
// the "delivery" is the structured log line plus the stored row, which is
// exactly what the UI feed renders.
func (a *api) send(w http.ResponseWriter, r *http.Request) {
	var req SendRequest
	if !httpx.DecodeJSON(w, r, &req) {
		return
	}
	if err := req.Validate(); err != nil {
		httpx.Error(w, http.StatusBadRequest, "validation_failed", err.Error())
		return
	}

	channel := strings.ToLower(strings.TrimSpace(req.Channel))
	if channel == "" {
		channel = ChannelEmail
	}

	notification := Notification{
		ID:        id.New("ntf"),
		Channel:   channel,
		Recipient: req.Recipient,
		Subject:   req.Subject,
		Body:      req.Body,
		BookingID: req.BookingID,
		EventID:   req.EventID,
		Status:    StatusSent,
		CreatedAt: time.Now().UTC(),
	}

	stored, err := a.store.Create(r.Context(), notification)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	a.logger.Info("notification dispatched",
		slog.String("notification_id", stored.ID),
		slog.String("channel", stored.Channel),
		slog.String("recipient", stored.Recipient),
		slog.String("subject", stored.Subject),
		slog.String("booking_id", stored.BookingID),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)
	httpx.JSON(w, http.StatusCreated, stored)
}

func (a *api) getNotification(w http.ResponseWriter, r *http.Request) {
	notification, err := a.store.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		a.fail(w, r, err)
		return
	}
	httpx.JSON(w, http.StatusOK, notification)
}

func (a *api) listNotifications(w http.ResponseWriter, r *http.Request) {
	limit := 50
	if raw := r.URL.Query().Get("limit"); raw != "" {
		if n, err := strconv.Atoi(raw); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}

	notifications, err := a.store.List(r.Context(), r.URL.Query().Get("booking_id"), limit)
	if err != nil {
		a.fail(w, r, err)
		return
	}

	httpx.JSON(w, http.StatusOK, map[string]any{
		"count":         len(notifications),
		"notifications": notifications,
	})
}

func (a *api) fail(w http.ResponseWriter, r *http.Request, err error) {
	if errors.Is(err, ErrNotFound) {
		httpx.Error(w, http.StatusNotFound, "notification_not_found", "no notification with that id")
		return
	}

	a.logger.Error("request failed",
		slog.Any("error", err),
		slog.String("path", r.URL.Path),
		slog.String("request_id", httpx.RequestIDFrom(r.Context())),
	)
	httpx.Error(w, http.StatusInternalServerError, "internal_error", "unexpected server error")
}
