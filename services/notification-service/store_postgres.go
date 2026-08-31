package main

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const schema = `
CREATE TABLE IF NOT EXISTS notifications (
    id         TEXT PRIMARY KEY,
    channel    TEXT        NOT NULL,
    recipient  TEXT        NOT NULL,
    subject    TEXT        NOT NULL,
    body       TEXT        NOT NULL DEFAULT '',
    booking_id TEXT        NOT NULL DEFAULT '',
    event_id   TEXT        NOT NULL DEFAULT '',
    status     TEXT        NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notifications_booking_id_idx ON notifications (booking_id);
CREATE INDEX IF NOT EXISTS notifications_created_at_idx ON notifications (created_at DESC);
`

const notificationColumns = `id, channel, recipient, subject, body, booking_id,
	event_id, status, created_at`

type postgresStore struct {
	pool *pgxpool.Pool
}

func newPostgresStore(ctx context.Context, pool *pgxpool.Pool) (*postgresStore, error) {
	if _, err := pool.Exec(ctx, schema); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &postgresStore{pool: pool}, nil
}

func scanNotification(row pgx.Row) (Notification, error) {
	var n Notification
	err := row.Scan(&n.ID, &n.Channel, &n.Recipient, &n.Subject, &n.Body,
		&n.BookingID, &n.EventID, &n.Status, &n.CreatedAt)
	return n, err
}

func (s *postgresStore) Create(ctx context.Context, n Notification) (Notification, error) {
	const query = `
		INSERT INTO notifications (` + notificationColumns + `)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
		RETURNING ` + notificationColumns

	row := s.pool.QueryRow(ctx, query, n.ID, n.Channel, n.Recipient, n.Subject,
		n.Body, n.BookingID, n.EventID, n.Status, n.CreatedAt)

	created, err := scanNotification(row)
	if err != nil {
		return Notification{}, fmt.Errorf("create notification: %w", err)
	}
	return created, nil
}

func (s *postgresStore) Get(ctx context.Context, notificationID string) (Notification, error) {
	row := s.pool.QueryRow(ctx,
		"SELECT "+notificationColumns+" FROM notifications WHERE id = $1", notificationID)

	n, err := scanNotification(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Notification{}, ErrNotFound
	}
	if err != nil {
		return Notification{}, fmt.Errorf("get notification: %w", err)
	}
	return n, nil
}

func (s *postgresStore) List(ctx context.Context, bookingID string, limit int) ([]Notification, error) {
	query := "SELECT " + notificationColumns + " FROM notifications"
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
		return nil, fmt.Errorf("list notifications: %w", err)
	}
	defer rows.Close()

	notifications := make([]Notification, 0, 16)
	for rows.Next() {
		n, err := scanNotification(rows)
		if err != nil {
			return nil, fmt.Errorf("scan notification: %w", err)
		}
		notifications = append(notifications, n)
	}
	return notifications, rows.Err()
}

func (s *postgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *postgresStore) Close() { s.pool.Close() }
