package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/tirucloud/eventhub/internal/httpx"
	"github.com/tirucloud/eventhub/internal/id"
)

// bookingError carries an HTTP status through the saga so the handler can
// report the right code without re-deriving it.
type bookingError struct {
	status  int
	code    string
	message string
}

func (e *bookingError) Error() string { return e.message }

// orchestrator runs the booking saga across event, payment and notification.
//
// There is no distributed transaction here — there cannot be, since each
// service owns its own state. Instead every step that changes remote state has
// a compensating action, and the saga runs them in reverse on failure. That is
// the pattern worth pausing on during the session.
type orchestrator struct {
	store   Store
	clients *clients
	logger  *slog.Logger
}

// compensationTimeout bounds the rollback calls. They run on a detached
// context so that a client who hangs up mid-request cannot leave seats
// reserved forever.
const compensationTimeout = 10 * time.Second

// Book executes the happy path and unwinds cleanly on any failure:
//
//  1. read the event            (no state change)
//  2. reserve seats             ← compensate with release
//  3. record a PENDING booking
//  4. charge the customer       ← compensate with refund
//  5. mark the booking CONFIRMED
//  6. notify the customer       (best effort, never rolls anything back)
func (o *orchestrator) Book(ctx context.Context, req CreateBookingRequest) (Booking, error) {
	log := o.logger.With(slog.String("request_id", httpx.RequestIDFrom(ctx)))

	// Step 1: price the booking from event-service, never from the client.
	event, err := o.clients.getEvent(ctx, req.EventID)
	if err != nil {
		var remote *httpx.RemoteError
		if errors.As(err, &remote) && remote.Status == http.StatusNotFound {
			return Booking{}, &bookingError{http.StatusNotFound, "event_not_found", "no event with that id"}
		}
		log.Error("could not read event", slog.Any("error", err), slog.String("event_id", req.EventID))
		return Booking{}, &bookingError{http.StatusBadGateway, "event_service_unavailable", "could not reach event-service"}
	}

	currency := event.Currency
	if currency == "" {
		currency = "INR"
	}

	// Step 2: hold the inventory before taking any money.
	if err := o.clients.reserveSeats(ctx, req.EventID, req.Seats); err != nil {
		var remote *httpx.RemoteError
		if errors.As(err, &remote) && remote.Status == http.StatusConflict {
			return Booking{}, &bookingError{http.StatusConflict, "insufficient_seats",
				fmt.Sprintf("only %d seats remain for %s", event.AvailableSeats, event.Name)}
		}
		log.Error("seat reservation failed", slog.Any("error", err), slog.String("event_id", req.EventID))
		return Booking{}, &bookingError{http.StatusBadGateway, "event_service_unavailable", "could not reserve seats"}
	}

	now := time.Now().UTC()
	booking := Booking{
		ID:            id.New("bkg"),
		EventID:       event.ID,
		EventName:     event.Name,
		CustomerName:  req.CustomerName,
		CustomerEmail: req.CustomerEmail,
		Seats:         req.Seats,
		AmountCents:   event.PriceCents * int64(req.Seats),
		Currency:      currency,
		Status:        StatusPending,
		CreatedAt:     now,
		UpdatedAt:     now,
	}

	// Step 3: persist the intent. If the process dies after this point there is
	// a durable record of what was in flight.
	booking, err = o.store.Create(ctx, booking)
	if err != nil {
		o.releaseSeats(ctx, booking, "booking_persist_failed")
		log.Error("could not persist booking", slog.Any("error", err))
		return Booking{}, &bookingError{http.StatusInternalServerError, "internal_error", "could not record booking"}
	}

	log.Info("booking pending",
		slog.String("booking_id", booking.ID),
		slog.String("event_id", booking.EventID),
		slog.Int("seats", booking.Seats),
		slog.Int64("amount_cents", booking.AmountCents),
	)

	// Step 4: take the money.
	payment, err := o.clients.charge(ctx, booking, req.Method())
	if err != nil {
		reason := "payment_failed"
		status := http.StatusBadGateway
		code := "payment_service_unavailable"
		message := "could not reach payment-service"

		var remote *httpx.RemoteError
		if errors.As(err, &remote) && remote.Status == http.StatusPaymentRequired {
			// A declined card is an expected outcome, not an incident.
			reason = remote.Code
			if payment.FailureReason != "" {
				reason = payment.FailureReason
			}
			status = http.StatusPaymentRequired
			code = "payment_declined"
			message = "payment was declined: " + reason
		} else {
			log.Error("payment call failed", slog.Any("error", err), slog.String("booking_id", booking.ID))
		}

		o.failBooking(ctx, booking, reason)
		return Booking{}, &bookingError{status, code, message}
	}

	// Step 5: the booking is now paid for; make it official.
	confirmed, err := o.store.UpdateStatus(ctx, booking.ID, StatusConfirmed,
		[]string{StatusPending}, payment.ID, "")
	if err != nil {
		// The charge succeeded but we could not record it. Refund rather than
		// keep money for a booking the customer will never see.
		log.Error("could not confirm booking, refunding",
			slog.Any("error", err),
			slog.String("booking_id", booking.ID),
			slog.String("payment_id", payment.ID))

		detached, cancel := context.WithTimeout(context.WithoutCancel(ctx), compensationTimeout)
		defer cancel()
		if refundErr := o.clients.refund(detached, payment.ID); refundErr != nil {
			log.Error("refund failed, manual intervention required",
				slog.Any("error", refundErr), slog.String("payment_id", payment.ID))
		}
		o.releaseSeats(ctx, booking, "confirm_failed")

		return Booking{}, &bookingError{http.StatusInternalServerError, "internal_error", "could not confirm booking"}
	}

	log.Info("booking confirmed",
		slog.String("booking_id", confirmed.ID),
		slog.String("payment_id", confirmed.PaymentID),
		slog.Int64("amount_cents", confirmed.AmountCents),
	)

	// Step 6: tell the customer. Best effort by design.
	o.notify(ctx, confirmed,
		"Booking confirmed: "+confirmed.EventName,
		fmt.Sprintf("Hi %s, your %d seat(s) for %s are confirmed. Booking reference %s.",
			confirmed.CustomerName, confirmed.Seats, confirmed.EventName, confirmed.ID))

	return confirmed, nil
}

// Cancel unwinds a confirmed booking: refund, release the seats, mark it
// cancelled, and let the customer know.
func (o *orchestrator) Cancel(ctx context.Context, bookingID string) (Booking, error) {
	log := o.logger.With(slog.String("request_id", httpx.RequestIDFrom(ctx)))

	// Move the status first. The guarded transition is what makes a double
	// cancel safe: the second request gets ErrNotCancellable and never refunds.
	cancelled, err := o.store.UpdateStatus(ctx, bookingID, StatusCancelled,
		[]string{StatusConfirmed}, "", "cancelled_by_customer")
	if err != nil {
		switch {
		case errors.Is(err, ErrNotFound):
			return Booking{}, &bookingError{http.StatusNotFound, "booking_not_found", "no booking with that id"}
		case errors.Is(err, ErrNotCancellable):
			return Booking{}, &bookingError{http.StatusConflict, "not_cancellable", "only confirmed bookings can be cancelled"}
		default:
			log.Error("could not cancel booking", slog.Any("error", err), slog.String("booking_id", bookingID))
			return Booking{}, &bookingError{http.StatusInternalServerError, "internal_error", "could not cancel booking"}
		}
	}

	if cancelled.PaymentID != "" {
		if err := o.clients.refund(ctx, cancelled.PaymentID); err != nil {
			// The booking is already cancelled; a failed refund is an
			// operations problem, not a reason to reject the customer request.
			log.Error("refund failed during cancellation",
				slog.Any("error", err),
				slog.String("booking_id", cancelled.ID),
				slog.String("payment_id", cancelled.PaymentID))
		}
	}

	o.releaseSeats(ctx, cancelled, "cancelled")

	log.Info("booking cancelled",
		slog.String("booking_id", cancelled.ID),
		slog.Int("seats", cancelled.Seats))

	o.notify(ctx, cancelled,
		"Booking cancelled: "+cancelled.EventName,
		fmt.Sprintf("Hi %s, booking %s has been cancelled and any payment refunded.",
			cancelled.CustomerName, cancelled.ID))

	return cancelled, nil
}

// failBooking marks the booking FAILED and gives the seats back.
func (o *orchestrator) failBooking(ctx context.Context, booking Booking, reason string) {
	detached, cancel := context.WithTimeout(context.WithoutCancel(ctx), compensationTimeout)
	defer cancel()

	if _, err := o.store.UpdateStatus(detached, booking.ID, StatusFailed,
		[]string{StatusPending}, "", reason); err != nil {
		o.logger.Error("could not mark booking failed",
			slog.Any("error", err), slog.String("booking_id", booking.ID))
	}

	o.releaseSeats(ctx, booking, reason)

	booking.Status = StatusFailed
	booking.FailureReason = reason
	o.notify(ctx, booking,
		"Booking failed: "+booking.EventName,
		fmt.Sprintf("Hi %s, we could not complete booking %s (%s). You have not been charged.",
			booking.CustomerName, booking.ID, reason))
}

// releaseSeats returns held inventory. It runs on a detached context because
// compensation must complete even when the caller has already given up.
func (o *orchestrator) releaseSeats(ctx context.Context, booking Booking, reason string) {
	detached, cancel := context.WithTimeout(context.WithoutCancel(ctx), compensationTimeout)
	defer cancel()

	if err := o.clients.releaseSeats(detached, booking.EventID, booking.Seats); err != nil {
		// Seats stay held until someone intervenes, so this is loud on purpose.
		o.logger.Error("compensation failed: seats not released",
			slog.Any("error", err),
			slog.String("booking_id", booking.ID),
			slog.String("event_id", booking.EventID),
			slog.Int("seats", booking.Seats),
			slog.String("reason", reason))
		return
	}

	o.logger.Info("compensation applied: seats released",
		slog.String("booking_id", booking.ID),
		slog.String("event_id", booking.EventID),
		slog.Int("seats", booking.Seats),
		slog.String("reason", reason))
}

// notify sends a customer message without ever failing the caller.
func (o *orchestrator) notify(ctx context.Context, booking Booking, subject, message string) {
	detached, cancel := context.WithTimeout(context.WithoutCancel(ctx), compensationTimeout)
	defer cancel()

	if err := o.clients.notify(detached, booking, subject, message); err != nil {
		o.logger.Warn("notification not delivered",
			slog.Any("error", err),
			slog.String("booking_id", booking.ID))
	}
}
