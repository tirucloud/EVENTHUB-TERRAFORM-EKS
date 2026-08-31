#!/usr/bin/env bash
# End-to-end check of the EventHub booking saga.
#
#   ./scripts/smoke-test.sh                        # against docker compose
#   BASE_URL=https://thirucloud.shop ./scripts/smoke-test.sh
#
#   # Bypass DNS entirely -- useful before delegation has propagated, or when a
#   # stale /etc/hosts entry is shadowing the real record:
#   BASE_URL=https://thirucloud.shop RESOLVE_IP=1.2.3.4 ./scripts/smoke-test.sh
#
# It exercises both paths that matter: a successful booking, and a declined
# payment that must roll the seat reservation back. If compensation is broken,
# step 5 fails loudly instead of silently leaking inventory.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
SEATS="${SEATS:-2}"
EMAIL="${EMAIL:-smoke-test@eventhub.local}"

# RESOLVE_IP pins the hostname to an address, the way `curl --resolve` does, so
# the test can run before DNS delegation has propagated or when something local
# (a stale /etc/hosts line, a captive resolver) is answering incorrectly.
CURL_OPTS=()
if [ -n "${RESOLVE_IP:-}" ]; then
    _host="${BASE_URL#*://}"; _host="${_host%%/*}"; _host="${_host%%:*}"
    CURL_OPTS+=(--resolve "${_host}:443:${RESOLVE_IP}" --resolve "${_host}:80:${RESOLVE_IP}")
fi

# Every request in this script goes through here so RESOLVE_IP applies uniformly.
curl_() { curl "${CURL_OPTS[@]}" "$@"; }

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$1"; exit 1; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# jget FILE KEYPATH — read a value out of a JSON file without needing jq.
jget() {
    python3 -c "
import json,sys
data = json.load(open(sys.argv[1]))
for key in sys.argv[2].split('.'):
    data = data[int(key)] if key.isdigit() else data[key]
print(data)
" "$1" "$2"
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

step "0. Health"
curl_ -sf "${BASE_URL}/health" >/dev/null || fail "frontend-service is not healthy"
pass "frontend-service is healthy"

step "1. Catalogue"
curl_ -sf "${BASE_URL}/api/events" -o "${tmp}/events.json" || fail "could not list events"
event_count="$(jget "${tmp}/events.json" count)"
[ "${event_count}" -gt 0 ] || fail "catalogue is empty"

event_id="$(jget "${tmp}/events.json" events.0.id)"
event_name="$(jget "${tmp}/events.json" events.0.name)"
seats_before="$(jget "${tmp}/events.json" events.0.available_seats)"
pass "${event_count} events; using '${event_name}' with ${seats_before} seats free"

step "2. Successful booking"
http_code="$(curl_ -s -o "${tmp}/booking.json" -w '%{http_code}' \
    -X POST "${BASE_URL}/api/bookings" \
    -H 'Content-Type: application/json' \
    -d "{\"event_id\":\"${event_id}\",\"seats\":${SEATS},\"customer_name\":\"Smoke Test\",\"customer_email\":\"${EMAIL}\",\"payment_method\":\"card\"}")"

[ "${http_code}" = "201" ] || fail "expected 201, got ${http_code}: $(cat "${tmp}/booking.json")"

booking_id="$(jget "${tmp}/booking.json" id)"
booking_status="$(jget "${tmp}/booking.json" status)"
payment_id="$(jget "${tmp}/booking.json" payment_id)"

[ "${booking_status}" = "CONFIRMED" ] || fail "expected CONFIRMED, got ${booking_status}"
[ -n "${payment_id}" ] || fail "booking has no payment id"
pass "booking ${booking_id} confirmed with payment ${payment_id}"

step "3. Inventory decremented"
curl_ -sf "${BASE_URL}/api/events/${event_id}" -o "${tmp}/event.json"
seats_after="$(jget "${tmp}/event.json" available_seats)"
expected=$((seats_before - SEATS))
[ "${seats_after}" -eq "${expected}" ] || fail "expected ${expected} seats, found ${seats_after}"
pass "seats went ${seats_before} -> ${seats_after}"

step "4. Declined payment is rejected"
http_code="$(curl_ -s -o "${tmp}/declined.json" -w '%{http_code}' \
    -X POST "${BASE_URL}/api/bookings" \
    -H 'Content-Type: application/json' \
    -d "{\"event_id\":\"${event_id}\",\"seats\":${SEATS},\"customer_name\":\"Smoke Test\",\"customer_email\":\"${EMAIL}\",\"payment_method\":\"declined-card\"}")"

[ "${http_code}" = "402" ] || fail "expected 402 Payment Required, got ${http_code}: $(cat "${tmp}/declined.json")"
pass "declined card rejected with 402"

step "5. Compensation released the held seats"
# The saga releases seats on a detached context, so give it a moment to land.
for _ in $(seq 1 10); do
    curl_ -sf "${BASE_URL}/api/events/${event_id}" -o "${tmp}/event.json"
    [ "$(jget "${tmp}/event.json" available_seats)" -eq "${seats_after}" ] && break
    sleep 0.5
done

seats_now="$(jget "${tmp}/event.json" available_seats)"
[ "${seats_now}" -eq "${seats_after}" ] || fail "compensation leaked inventory: expected ${seats_after}, found ${seats_now}"
pass "inventory still ${seats_now}; no seats leaked by the failed booking"

step "6. Notifications were recorded"
curl_ -sf "${BASE_URL}/api/notifications?limit=100" -o "${tmp}/notifications.json"
notification_count="$(jget "${tmp}/notifications.json" count)"
[ "${notification_count}" -ge 2 ] || fail "expected at least 2 notifications, found ${notification_count}"
pass "${notification_count} notifications in the feed"

step "7. Cancellation refunds and restores inventory"
http_code="$(curl_ -s -o "${tmp}/cancelled.json" -w '%{http_code}' \
    -X POST "${BASE_URL}/api/bookings/${booking_id}/cancel")"
[ "${http_code}" = "200" ] || fail "expected 200, got ${http_code}: $(cat "${tmp}/cancelled.json")"
[ "$(jget "${tmp}/cancelled.json" status)" = "CANCELLED" ] || fail "booking was not cancelled"
pass "booking ${booking_id} cancelled"

for _ in $(seq 1 10); do
    curl_ -sf "${BASE_URL}/api/events/${event_id}" -o "${tmp}/event.json"
    [ "$(jget "${tmp}/event.json" available_seats)" -eq "${seats_before}" ] && break
    sleep 0.5
done

seats_final="$(jget "${tmp}/event.json" available_seats)"
[ "${seats_final}" -eq "${seats_before}" ] || fail "expected ${seats_before} seats back, found ${seats_final}"
pass "inventory restored to ${seats_final}"

step "8. Double cancel is rejected"
http_code="$(curl_ -s -o /dev/null -w '%{http_code}' \
    -X POST "${BASE_URL}/api/bookings/${booking_id}/cancel")"
[ "${http_code}" = "409" ] || fail "expected 409 on repeat cancel, got ${http_code}"
pass "repeat cancellation rejected with 409, so no double refund"

printf '\n\033[32mAll checks passed against %s\033[0m\n\n' "${BASE_URL}"
