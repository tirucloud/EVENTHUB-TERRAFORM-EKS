package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const schema = `
CREATE TABLE IF NOT EXISTS bookings (
    id             TEXT PRIMARY KEY,
    event_id       TEXT        NOT NULL,
    event_name     TEXT        NOT NULL DEFAULT '',
    customer_name  TEXT        NOT NULL,
    customer_email TEXT        NOT NULL,
    seats          INTEGER     NOT NULL CHECK (seats > 0),
    amount_cents   BIGINT      NOT NULL CHECK (amount_cents >= 0),
    currency       TEXT        NOT NULL DEFAULT 'INR',
    status         TEXT        NOT NULL,
    payment_id     TEXT        NOT NULL DEFAULT '',
    failure_reason TEXT        NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS bookings_email_idx    ON bookings (customer_email);
CREATE INDEX IF NOT EXISTS bookings_event_id_idx ON bookings (event_id);
`

const bookingColumns = `id, event_id, event_name, customer_name, customer_email,
	seats, amount_cents, currency, status, payment_id, failure_reason,
	created_at, updated_at`

type postgresStore struct {
	pool *pgxpool.Pool
}

func newPostgresStore(ctx context.Context, pool *pgxpool.Pool) (*postgresStore, error) {
	if _, err := pool.Exec(ctx, schema); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &postgresStore{pool: pool}, nil
}

func scanBooking(row pgx.Row) (Booking, error) {
	var b Booking
	err := row.Scan(&b.ID, &b.EventID, &b.EventName, &b.CustomerName, &b.CustomerEmail,
		&b.Seats, &b.AmountCents, &b.Currency, &b.Status, &b.PaymentID,
		&b.FailureReason, &b.CreatedAt, &b.UpdatedAt)
	return b, err
}

func (s *postgresStore) Create(ctx context.Context, b Booking) (Booking, error) {
	const query = `
		INSERT INTO bookings (` + bookingColumns + `)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
		RETURNING ` + bookingColumns

	row := s.pool.QueryRow(ctx, query, b.ID, b.EventID, b.EventName, b.CustomerName,
		b.CustomerEmail, b.Seats, b.AmountCents, b.Currency, b.Status, b.PaymentID,
		b.FailureReason, b.CreatedAt, b.UpdatedAt)

	created, err := scanBooking(row)
	if err != nil {
		return Booking{}, fmt.Errorf("create booking: %w", err)
	}
	return created, nil
}

func (s *postgresStore) Get(ctx context.Context, bookingID string) (Booking, error) {
	row := s.pool.QueryRow(ctx, "SELECT "+bookingColumns+" FROM bookings WHERE id = $1", bookingID)

	b, err := scanBooking(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Booking{}, ErrNotFound
	}
	if err != nil {
		return Booking{}, fmt.Errorf("get booking: %w", err)
	}
	return b, nil
}

func (s *postgresStore) List(ctx context.Context, email string, limit int) ([]Booking, error) {
	query := "SELECT " + bookingColumns + " FROM bookings"
	args := []any{}

	if email != "" {
		args = append(args, email)
		query += " WHERE customer_email = $1"
	}
	query += " ORDER BY created_at DESC, id DESC"

	if limit > 0 {
		args = append(args, limit)
		query += fmt.Sprintf(" LIMIT $%d", len(args))
	}

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list bookings: %w", err)
	}
	defer rows.Close()

	bookings := make([]Booking, 0, 16)
	for rows.Next() {
		b, err := scanBooking(rows)
		if err != nil {
			return nil, fmt.Errorf("scan booking: %w", err)
		}
		bookings = append(bookings, b)
	}
	return bookings, rows.Err()
}

// UpdateStatus performs a guarded transition. The allowed source states are
// part of the WHERE clause, so two concurrent cancel requests cannot both
// succeed and issue two refunds.
func (s *postgresStore) UpdateStatus(ctx context.Context, bookingID, status string, allowedFrom []string, paymentID, failureReason string) (Booking, error) {
	const query = `
		UPDATE bookings
		   SET status         = $2,
		       payment_id     = CASE WHEN $3 = '' THEN payment_id     ELSE $3 END,
		       failure_reason = CASE WHEN $4 = '' THEN failure_reason ELSE $4 END,
		       updated_at     = now()
		 WHERE id = $1 AND status = ANY($5)
		RETURNING ` + bookingColumns

	row := s.pool.QueryRow(ctx, query, bookingID, status, paymentID, failureReason, allowedFrom)

	b, err := scanBooking(row)
	if err == nil {
		return b, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Booking{}, fmt.Errorf("update booking status: %w", err)
	}

	// Nothing updated: distinguish "missing" from "wrong current state".
	if _, getErr := s.Get(ctx, bookingID); getErr != nil {
		return Booking{}, getErr
	}
	return Booking{}, ErrNotCancellable
}

func (s *postgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *postgresStore) Close() { s.pool.Close() }
