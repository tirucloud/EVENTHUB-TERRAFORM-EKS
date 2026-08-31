package main

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// schema is applied on every start. Using IF NOT EXISTS keeps startup
// idempotent, which is what lets a Deployment scale to three replicas without
// the pods fighting over migrations.
const schema = `
CREATE TABLE IF NOT EXISTS events (
    id              TEXT PRIMARY KEY,
    name            TEXT        NOT NULL,
    description     TEXT        NOT NULL DEFAULT '',
    category        TEXT        NOT NULL DEFAULT '',
    venue           TEXT        NOT NULL,
    city            TEXT        NOT NULL DEFAULT '',
    starts_at       TIMESTAMPTZ NOT NULL,
    total_seats     INTEGER     NOT NULL CHECK (total_seats >= 0),
    available_seats INTEGER     NOT NULL CHECK (available_seats >= 0),
    price_cents     BIGINT      NOT NULL DEFAULT 0,
    currency        TEXT        NOT NULL DEFAULT 'INR',
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT available_within_total CHECK (available_seats <= total_seats)
);

CREATE INDEX IF NOT EXISTS events_starts_at_idx ON events (starts_at);
CREATE INDEX IF NOT EXISTS events_city_idx      ON events (lower(city));
`

const eventColumns = `id, name, description, category, venue, city, starts_at,
	total_seats, available_seats, price_cents, currency, created_at, updated_at`

// postgresStore persists events in the PostgreSQL StatefulSet, whose data
// directory lives on an EBS gp3 volume provisioned by the EBS CSI driver.
type postgresStore struct {
	pool *pgxpool.Pool
}

func newPostgresStore(ctx context.Context, pool *pgxpool.Pool) (*postgresStore, error) {
	if _, err := pool.Exec(ctx, schema); err != nil {
		return nil, fmt.Errorf("apply schema: %w", err)
	}
	return &postgresStore{pool: pool}, nil
}

func scanEvent(row pgx.Row) (Event, error) {
	var e Event
	err := row.Scan(&e.ID, &e.Name, &e.Description, &e.Category, &e.Venue, &e.City,
		&e.StartsAt, &e.TotalSeats, &e.AvailableSeats, &e.PriceCents, &e.Currency,
		&e.CreatedAt, &e.UpdatedAt)
	return e, err
}

func (s *postgresStore) List(ctx context.Context, f ListFilter) ([]Event, error) {
	var (
		clauses []string
		args    []any
	)

	if f.City != "" {
		args = append(args, f.City)
		clauses = append(clauses, fmt.Sprintf("lower(city) = lower($%d)", len(args)))
	}
	if f.Category != "" {
		args = append(args, f.Category)
		clauses = append(clauses, fmt.Sprintf("lower(category) = lower($%d)", len(args)))
	}
	if f.Query != "" {
		args = append(args, "%"+strings.ToLower(f.Query)+"%")
		clauses = append(clauses, fmt.Sprintf(
			"(lower(name) LIKE $%d OR lower(description) LIKE $%d OR lower(venue) LIKE $%d)",
			len(args), len(args), len(args)))
	}

	query := "SELECT " + eventColumns + " FROM events"
	if len(clauses) > 0 {
		query += " WHERE " + strings.Join(clauses, " AND ")
	}
	query += " ORDER BY starts_at ASC, id ASC"

	rows, err := s.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("list events: %w", err)
	}
	defer rows.Close()

	events := make([]Event, 0, 16)
	for rows.Next() {
		e, err := scanEvent(rows)
		if err != nil {
			return nil, fmt.Errorf("scan event: %w", err)
		}
		events = append(events, e)
	}
	return events, rows.Err()
}

func (s *postgresStore) Get(ctx context.Context, eventID string) (Event, error) {
	row := s.pool.QueryRow(ctx, "SELECT "+eventColumns+" FROM events WHERE id = $1", eventID)

	e, err := scanEvent(row)
	if errors.Is(err, pgx.ErrNoRows) {
		return Event{}, ErrNotFound
	}
	if err != nil {
		return Event{}, fmt.Errorf("get event: %w", err)
	}
	return e, nil
}

func (s *postgresStore) Create(ctx context.Context, e Event) (Event, error) {
	const query = `
		INSERT INTO events (` + eventColumns + `)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)
		RETURNING ` + eventColumns

	row := s.pool.QueryRow(ctx, query, e.ID, e.Name, e.Description, e.Category, e.Venue,
		e.City, e.StartsAt, e.TotalSeats, e.AvailableSeats, e.PriceCents, e.Currency,
		e.CreatedAt, e.UpdatedAt)

	created, err := scanEvent(row)
	if err != nil {
		return Event{}, fmt.Errorf("create event: %w", err)
	}
	return created, nil
}

func (s *postgresStore) Delete(ctx context.Context, eventID string) error {
	tag, err := s.pool.Exec(ctx, "DELETE FROM events WHERE id = $1", eventID)
	if err != nil {
		return fmt.Errorf("delete event: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

// AdjustSeats does the whole reservation in one statement. The bounds live in
// the WHERE clause, so two concurrent bookings for the last seat are resolved
// by PostgreSQL's row lock rather than by a read-modify-write race in Go.
func (s *postgresStore) AdjustSeats(ctx context.Context, eventID string, delta int) (Event, error) {
	const query = `
		UPDATE events
		   SET available_seats = available_seats + $2,
		       updated_at      = now()
		 WHERE id = $1
		   AND available_seats + $2 >= 0
		   AND available_seats + $2 <= total_seats
		RETURNING ` + eventColumns

	row := s.pool.QueryRow(ctx, query, eventID, delta)

	e, err := scanEvent(row)
	if err == nil {
		return e, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return Event{}, fmt.Errorf("adjust seats: %w", err)
	}

	// No row was updated. Read the event back to report why: either it does not
	// exist, or the bounds check rejected the change.
	current, getErr := s.Get(ctx, eventID)
	if getErr != nil {
		return Event{}, getErr
	}
	if current.AvailableSeats+delta < 0 {
		return Event{}, ErrInsufficientSeats
	}
	return Event{}, ErrTooManySeats
}

func (s *postgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }

func (s *postgresStore) Close() { s.pool.Close() }

// count reports how many events exist, so main can decide whether to seed.
func (s *postgresStore) count(ctx context.Context) (int, error) {
	var n int
	if err := s.pool.QueryRow(ctx, "SELECT count(*) FROM events").Scan(&n); err != nil {
		return 0, fmt.Errorf("count events: %w", err)
	}
	return n, nil
}
