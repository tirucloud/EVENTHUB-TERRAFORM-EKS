package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const schema = `
CREATE TABLE IF NOT EXISTS payments (
    id             TEXT PRIMARY KEY,
    booking_id     TEXT        NOT NULL,
    amount_cents   BIGINT      NOT NULL CHECK (amount_cents > 0),
    currency       TEXT        NOT NULL DEFAULT 'INR',
    method         TEXT        NOT NULL,
    status         TEXT        NOT NULL,
    reference      TEXT        NOT NULL,
    failure_reason TEXT        NOT NULL DEFAULT '',
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payments_booking_id_idx ON payments (booking_id);
`

const paymentColumns = `id, booking_id, amount_cents, currency, method, status,
	reference, failure_reason, created_at, updated_at`

type postgresStore struct {
	pool *pgxpool.Pool
}

func newPostgresStore(ctx context.Context, pool *pgxpool.Pool) (*postgresStore, error) {
	if _, err := pool.Exec(ctx, schema); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &postgresStore{pool: pool}, nil
}

func scanPayment(row pgx.Row) (Payment, error) {
	var p Payment
	err := row.Scan(&p.ID, &p.BookingID, &p.AmountCents, &p.Currency, &p.Method,
		&p.Status, &p.Reference, &p.FailureReason, &p.CreatedAt, &p.UpdatedAt)
	return p, err
}

func (s *postgresStore) Create(ctx context.Context, p Payment) (Payment, error) {
	const query = `
		INSERT INTO payments (` + paymentColumns + `)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)
		RETURNING ` + paymentColumns

	row := s.pool.QueryRow(ctx, query, p.ID, p.BookingID, p.AmountCents, p.Currency,
		p.Method, p.Status, p.Reference, p.FailureReason, p.CreatedAt, p.UpdatedAt)

	created, err := scanPayment(row)
	if err != nil {
		return Payment{}, fmt.Errorf("create payment: %w", err)
	}
	return created, nil
}

func (s *postgresStore) Get(ctx context.Context, paymentID string) (Payment, error) {
	row := s.pool.QueryRow(ctx, "SELECT "+paymentColumns+" FROM payments WHERE id = $1", paymentID)

	p, err := scanPayment(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, ErrNotFound
	}
	if err != nil {
		return Payment{}, fmt.Errorf("get payment: %w", err)
	}
	return p, nil
}

func (s *postgresStore) List(ctx context.Context, bookingID string, limit int) ([]Payment, error) {
	query := "SELECT " + paymentColumns + " FROM payments"
	args := []any{}

	if bookingID != "" {
		args = append(args, bookingID)
		query += " WHERE booking_id = $1"
	}
	query += " ORDER BY created_at DESC, id DESC"

	if limit > 0 {
		args = append(args, limit)
		query += fmt.Sprintf(" LIMIT $%d", len(args))
	}

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list payments: %w", err)
	}
	defer rows.Close()

	payments := make([]Payment, 0, 16)
	for rows.Next() {
		p, err := scanPayment(rows)
		if err != nil {
			return nil, fmt.Errorf("scan payment: %w", err)
		}
		payments = append(payments, p)
	}
	return payments, rows.Err()
}

// Refund only moves AUTHORIZED to REFUNDED. The status guard lives in the WHERE
// clause so a duplicate cancel request cannot refund the same payment twice.
func (s *postgresStore) Refund(ctx context.Context, paymentID string) (Payment, error) {
	const query = `
		UPDATE payments
		   SET status = $2, updated_at = now()
		 WHERE id = $1 AND status = $3
		RETURNING ` + paymentColumns

	row := s.pool.QueryRow(ctx, query, paymentID, StatusRefunded, StatusAuthorized)

	p, err := scanPayment(row)
	if err == nil {
		return p, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Payment{}, fmt.Errorf("refund payment: %w", err)
	}

	// Nothing updated: either the payment is missing or it was not authorised.
	if _, getErr := s.Get(ctx, paymentID); getErr != nil {
		return Payment{}, getErr
	}
	return Payment{}, ErrNotRefundable
}

func (s *postgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *postgresStore) Close() { s.pool.Close() }
