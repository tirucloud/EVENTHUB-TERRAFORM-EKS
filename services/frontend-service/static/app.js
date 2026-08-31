// EventHub UI. Plain ES modules-free JavaScript on purpose: no build step, no
// bundler, nothing to configure. Every call goes to the same origin and is
// reverse-proxied by frontend-service to the service that owns the data.

const state = {
  view: 'events',
  events: [],
  search: '',
  selectedEvent: null,
};

const $ = (selector) => document.querySelector(selector);

const money = (cents, currency = 'INR') =>
  new Intl.NumberFormat('en-IN', { style: 'currency', currency, maximumFractionDigits: 0 })
    .format((cents || 0) / 100);

const when = (iso) =>
  new Date(iso).toLocaleString('en-IN', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit',
  });

const ago = (iso) => {
  const seconds = Math.round((Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3600) return `${Math.round(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)}h ago`;
  return when(iso);
};

const escapeHTML = (value) =>
  String(value ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// ---------------------------------------------------------------- transport

/**
 * api issues a JSON request and turns any non-2xx response into a thrown Error
 * carrying the message the backend supplied. Every service returns the same
 * {error, message} envelope, so one handler covers all four.
 */
async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...options,
    body: options.body ? JSON.stringify(options.body) : undefined,
  });

  const text = await response.text();
  const payload = text ? JSON.parse(text) : null;

  if (!response.ok) {
    const error = new Error(payload?.message || `request failed with ${response.status}`);
    error.code = payload?.error;
    error.status = response.status;
    throw error;
  }
  return payload;
}

function banner(message, kind = 'ok') {
  const el = $('#banner');
  el.textContent = message;
  el.className = `banner ${kind}`;
  el.hidden = false;
  clearTimeout(banner.timer);
  banner.timer = setTimeout(() => { el.hidden = true; }, 6000);
}

// ------------------------------------------------------------------- events

async function loadEvents() {
  const grid = $('#events-grid');
  try {
    const query = state.search ? `?q=${encodeURIComponent(state.search)}` : '';
    const data = await api(`/api/events${query}`);
    state.events = data.events || [];
  } catch (err) {
    grid.innerHTML = `<div class="empty">Could not load events: ${escapeHTML(err.message)}</div>`;
    return;
  }

  if (!state.events.length) {
    grid.innerHTML = '<div class="empty">No events match your search.</div>';
    return;
  }

  grid.innerHTML = state.events.map((event) => {
    const soldOut = event.available_seats <= 0;
    const scarce = !soldOut && event.available_seats <= event.total_seats * 0.1;

    let pill = `<span class="pill info">${event.available_seats} left</span>`;
    if (soldOut) pill = '<span class="pill soldout">Sold out</span>';
    else if (scarce) pill = `<span class="pill warn">Only ${event.available_seats} left</span>`;

    return `
      <article class="card">
        <div class="card-title">
          <h3>${escapeHTML(event.name)}</h3>
          ${pill}
        </div>
        <div class="card-meta">
          <span>📍 ${escapeHTML(event.venue)}, ${escapeHTML(event.city)}</span>
          <span>🗓️ ${when(event.starts_at)}</span>
          <span>🏷️ ${escapeHTML(event.category || 'general')}</span>
        </div>
        <div class="card-foot">
          <span class="price">${money(event.price_cents, event.currency)}</span>
          <button class="btn btn-primary btn-sm" data-book="${event.id}" ${soldOut ? 'disabled' : ''}>
            ${soldOut ? 'Sold out' : 'Book'}
          </button>
        </div>
      </article>`;
  }).join('');
}

// ----------------------------------------------------------------- bookings

async function loadBookings() {
  const list = $('#bookings-list');
  let bookings = [];

  try {
    const data = await api('/api/bookings?limit=100');
    bookings = data.bookings || [];
  } catch (err) {
    list.innerHTML = `<div class="empty">Could not load bookings: ${escapeHTML(err.message)}</div>`;
    return;
  }

  if (!bookings.length) {
    list.innerHTML = '<div class="empty">No bookings yet. Book something from the Events tab.</div>';
    return;
  }

  const pillClass = { CONFIRMED: 'ok', PENDING: 'warn', FAILED: 'bad', CANCELLED: '' };

  list.innerHTML = bookings.map((booking) => `
    <div class="row status-${booking.status.toLowerCase()}">
      <div class="row-main">
        <strong>${escapeHTML(booking.event_name || booking.event_id)}</strong>
        <span class="mono">${escapeHTML(booking.id)}</span>
        <span class="muted">
          ${booking.seats} seat(s) · ${escapeHTML(booking.customer_email)}
          ${booking.failure_reason ? ` · ${escapeHTML(booking.failure_reason)}` : ''}
        </span>
      </div>
      <div class="row-side">
        <span class="price">${money(booking.amount_cents, booking.currency)}</span>
        <span class="pill ${pillClass[booking.status] ?? ''}">${booking.status}</span>
        ${booking.status === 'CONFIRMED'
          ? `<button class="btn btn-danger btn-sm" data-cancel="${booking.id}">Cancel</button>`
          : ''}
      </div>
    </div>`).join('');
}

// ------------------------------------------------------------ notifications

async function loadNotifications() {
  const list = $('#notifications-list');
  let notifications = [];

  try {
    const data = await api('/api/notifications?limit=100');
    notifications = data.notifications || [];
  } catch (err) {
    list.innerHTML = `<div class="empty">Could not load notifications: ${escapeHTML(err.message)}</div>`;
    return;
  }

  if (!notifications.length) {
    list.innerHTML = '<div class="empty">Nothing sent yet.</div>';
    return;
  }

  const icon = { email: '✉️', sms: '💬', push: '🔔' };

  list.innerHTML = notifications.map((n) => `
    <div class="row">
      <div class="row-main">
        <strong>${icon[n.channel] ?? '📨'} ${escapeHTML(n.subject)}</strong>
        <span class="muted">${escapeHTML(n.body)}</span>
        <span class="mono">to ${escapeHTML(n.recipient)} · ${ago(n.created_at)}</span>
      </div>
      <span class="pill ${n.status === 'SENT' ? 'ok' : 'bad'}">${n.status}</span>
    </div>`).join('');
}

// -------------------------------------------------------------- interaction

function openBookingDialog(eventID) {
  const event = state.events.find((e) => e.id === eventID);
  if (!event) return;

  state.selectedEvent = event;
  $('#dialog-title').textContent = `Book ${event.name}`;
  $('#dialog-subtitle').textContent =
    `${money(event.price_cents, event.currency)} per seat · ${event.available_seats} available`;
  $('#booking-form').elements.seats.max = Math.min(10, event.available_seats);
  $('#booking-dialog').showModal();
}

async function submitBooking(form) {
  const button = $('#confirm-btn');
  const data = Object.fromEntries(new FormData(form));

  button.disabled = true;
  button.textContent = 'Processing…';

  try {
    const booking = await api('/api/bookings', {
      method: 'POST',
      body: {
        event_id: state.selectedEvent.id,
        seats: Number(data.seats),
        customer_name: data.customer_name,
        customer_email: data.customer_email,
        payment_method: data.payment_method,
      },
    });

    banner(`Booking confirmed — reference ${booking.id}`, 'ok');
    $('#booking-dialog').close();
    switchView('bookings');
  } catch (err) {
    // A declined payment lands here. The seats were already released by the
    // booking saga, so refreshing the events list shows inventory restored.
    banner(`Booking failed: ${err.message}`, 'bad');
    await loadEvents();
  } finally {
    button.disabled = false;
    button.textContent = 'Confirm booking';
  }
}

async function cancelBooking(bookingID) {
  try {
    await api(`/api/bookings/${bookingID}/cancel`, { method: 'POST' });
    banner('Booking cancelled and refunded', 'ok');
  } catch (err) {
    banner(`Could not cancel: ${err.message}`, 'bad');
  }
  await loadBookings();
}

function switchView(view) {
  state.view = view;

  document.querySelectorAll('.tab').forEach((tab) =>
    tab.classList.toggle('is-active', tab.dataset.view === view));
  document.querySelectorAll('.view').forEach((section) =>
    section.hidden = section.id !== `view-${view}`);

  refresh();
}

function refresh() {
  if (state.view === 'events') return loadEvents();
  if (state.view === 'bookings') return loadBookings();
  return loadNotifications();
}

// --------------------------------------------------------------- bootstrap

document.addEventListener('click', (event) => {
  const target = event.target;

  if (target.matches('.tab')) switchView(target.dataset.view);
  if (target.matches('[data-book]')) openBookingDialog(target.dataset.book);
  if (target.matches('[data-cancel]')) cancelBooking(target.dataset.cancel);
  if (target.matches('[data-refresh]')) refresh();
  if (target.matches('[data-close]')) $('#booking-dialog').close();
});

$('#booking-form').addEventListener('submit', (event) => {
  event.preventDefault();
  submitBooking(event.target);
});

let searchTimer;
$('#search').addEventListener('input', (event) => {
  state.search = event.target.value.trim();
  clearTimeout(searchTimer);
  searchTimer = setTimeout(loadEvents, 250);
});

// Show which pod served this page. Refreshing repeatedly across several
// replicas is the quickest way to make Kubernetes load balancing visible.
api('/api/meta')
  .then((meta) => { $('#pod-info').textContent = `served by ${meta.pod} (${meta.version})`; })
  .catch(() => { $('#pod-info').textContent = 'pod info unavailable'; });

loadEvents();
