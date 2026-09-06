# Offline logging

Let a caregiver open the installed PWA with no connection, log **feeds, diapers
and sleeps**, and have those entries sync — idempotently — once the device is
back online with a live session.

## Why it isn't a small change

Every write today runs through the LiveView websocket: the buttons and sheets in
`TryggWeb.DashboardLive` are `phx-click` / `phx-submit` events, photo uploads go
through the LiveView channel, and `Trygg.Log.create_entry/4` stamps `started_at`
server-side and broadcasts on the child's PubSub topic. When the socket is dead
nothing renders — the service worker serves the static `offline.html`.

So the offline path is a **second, LiveView-free capture path**: plain JS writing
to IndexedDB, flushed to a plain JSON endpoint. The *merge* side is easy — the
log is an append-only stream of independent events keyed by a client-generated
UUID, no shared mutable document.

## Scope

**In (Phases 1–4):** bottle feeds, diapers, past sleep, and a **running sleep
timer** (start/stop) captured offline; a **read cache** (recent entries + any
running sleep) so the offline screen isn't blind; batch sync on reconnect with
idempotent retries; **at most one running sleep per child** enforced on sync.

**Still deferred:** offline **photo** capture (needs blob storage in IndexedDB
+ a multipart upload endpoint — a self-contained follow-up).

---

## Phase 1 — server write path that doesn't need LiveView

### Migration

`add_client_id_to_log_entries`:

- `add :client_id, :binary_id` on `log_entries`, nullable — existing rows and the
  LiveView write path leave it `nil`.
- `create unique_index(:log_entries, [:child_id, :client_id], where: "client_id IS NOT NULL")`.

### Schema — `Trygg.Log.Entry`

- `field :client_id, Ecto.UUID`
- add `:client_id` to the `cast/3` list in `changeset/2`; not required.

### Context — `Trygg.Log.sync_entry/3`

`sync_entry(scope, child, attrs)`, sibling to `create_entry/4`:

- `Families.authorize!(scope, child, :caregiver)`.
- Require a well-formed `client_id` (`{:error, :missing_client_id}` otherwise).
- Trust the client's event time: accept any past `started_at` / `ended_at`;
  clamp a `started_at` more than 2 min in the future to now (clock skew).
- Look up `Repo.get_by(Entry, child_id: child.id, client_id: cid)`:
  - `nil` → insert with
    `on_conflict: {:replace, [:started_at, :ended_at, :data, :note, :updated_at]}`,
    `conflict_target: [:child_id, :client_id]` (race-safe) → broadcast `:created`.
  - found → `Entry.changeset(existing, attrs) |> Repo.update()` → broadcast `:updated`.
- Returns `{:ok, entry}` / `{:error, changeset}` like the other writers.
- `logged_by_id` = `scope.user.id` — the caregiver who synced.

### Endpoint — `POST /c/:id/log/entries`

Placed in `scope "/", TryggWeb` under `pipe_through [:browser, :require_authenticated_user]`,
next to the existing `POST /push/subscriptions` — same session auth, same CSRF
handling (`x-csrf-token` header from the `meta` tag), not bound to a live socket.

`TryggWeb.LogSyncController.create/2`:

- `Families.get_child!(scope, id)` (404/redirect on no access; `:caregiver`
  enforced again in the context).
- Body is a batch: `%{"entries" => [%{"client_id", "type", "started_at",
  "ended_at", "data", "note"}, ...]}`.
- Map each through `Log.sync_entry/3`; one bad item never fails the batch.
- `200` with per-item results:
  ```json
  { "results": [
    { "client_id": "…", "status": "ok", "id": 123 },
    { "client_id": "…", "status": "rejected", "errors": { "data": ["a feed needs an amount"] } }
  ]}
  ```
  `ok` → client deletes the row. `rejected` (validation) → client stops
  retrying and flags it. Non-2xx / redirect to log-in → client keeps the batch.

---

## Phase 2 — offline capture UI + local queue  *(implemented)*

### Build

- **No Dexie.** The repo keeps `assets/` free of `node_modules` (esbuild
  bundles straight from `deps/` and `vendor/`), so
  [`assets/js/offline/db.js`](../assets/js/offline/db.js) is a ~120-line promise
  wrapper over raw IndexedDB — all this feature needs is `add` / `getAll` /
  `get` / `delete` / `put` on two stores.
- A second esbuild entry point [`assets/js/offline.js`](../assets/js/offline.js)
  → `priv/static/assets/js/offline.js` (added to the `esbuild` args in
  `config/config.exs`). `offline.html` loads it by a **literal, undigested
  path** — `mix phx.digest` leaves the original file in place next to the
  hashed copy, so the URL is stable for the service worker to precache. Same
  pragmatic choice the SW already makes for `/`.

### IndexedDB — database `trygg-offline` ([db.js](../assets/js/offline/db.js))

- `queue` store, keyPath `clientId`. Row: `{clientId, childId, type, startedAt,
  endedAt, data, note, createdAt, attempts, status}` — `status` is
  `pending` | `rejected`.
- `context` store, keyPath `childId`. Row: `{childId, childName, unitSystem,
  canWrite, tz, updatedAt}` — the only data bridged from LiveView; the panel
  uses the most recently `updatedAt` row.

### Quick-logger — [`assets/js/offline/quick_log.js`](../assets/js/offline/quick_log.js)

`renderPanel(root, {onClose?})` builds a self-styled panel (injects its own
`<style>`, no dependency on `app.css`): **Bottle** (amount stepper in the
caregiver's unit + optional contents), **Diaper** (pee / poo / mixed, one tap),
**Past sleep** (start + end `datetime-local`), and a **Waiting to sync** list
with per-row remove. `enqueue()` writes a `queue` row (`crypto.randomUUID()`,
`startedAt` captured at tap time, times as UTC ISO strings, `data` shaped as
`Entry.changeset` expects), dispatches `trygg:queue-changed`, and calls
`flush()` best-effort. No photo control offline.

### Sync transport — [`assets/js/offline/sync.js`](../assets/js/offline/sync.js)

Phase 2 ships the **transport only**: `flush()` is single-flight, reads
`pending` rows, groups by child, `POST /c/:id/log/entries` with the
`x-csrf-token` header, then `queueDelete` on `ok` / marks `rejected` on
validation failure. A redirect or non-2xx leaves the whole group queued. The
**trigger wiring, retry backoff and periodic net are Phase 3** — for now
`flush()` only runs opportunistically right after an `enqueue()` and (in
`offline.js`) on `online` / `visibilitychange`.

### Context mirroring hook — [`assets/js/hooks/offline_context.js`](../assets/js/hooks/offline_context.js)

`phx-hook="OfflineContext"` on a hidden `#offline-context` div in
`DashboardLive.render/1` carrying `data-child-id` / `-child-name` /
`-unit-system` / `-can-write` / `-tz`. `mounted()` / `updated()` write it into
the `context` store (only when `canWrite`).

### Mount A — cold offline start

[`priv/static/offline.html`](../priv/static/offline.html) now hosts an
`#offline-app` div with a static "You're offline / Try again" fallback, and
loads `/assets/js/offline.js`, which replaces it with the quick-logger (or,
with no mirrored context yet, an "open once online first" message).
`/assets/js/offline.js` is precached in `priv/static/sw.js` (`SHELL`, cache
bumped to `trygg-shell-v6`).

### Mount B — went offline with the app already open

[`assets/js/offline/panel_toggle.js`](../assets/js/offline/panel_toggle.js),
wired from `app.js` as `installOfflinePanel(liveSocket)`, listens on
`liveSocket.socket` `onClose`/`onOpen` and `window` `offline`/`online`. It
shows a full-screen overlay panel only when `navigator.onLine` is false **and**
`liveSocket.isConnected()` is false (after a 1.5 s grace, so a deploy blip
doesn't flash it), and hides it on reconnect. Conservative by design; may need
tuning after real-device testing.

### Server tweak

`Trygg.Log.sync_entry/3` now also fills `ended_at` for a `feeding` when the
client leaves it blank (absent or explicit `null`) — mirrors `create_entry/4`
so feeds stay instantaneous regardless of client.

---

## Phase 3 — sync  *(implemented)*

### Trigger orchestration — [`assets/js/offline/auto_sync.js`](../assets/js/offline/auto_sync.js)

`sync.js` still owns the transport; `auto_sync.js` decides *when* it runs and
handles failure. `startAutoSync({liveSocket})` (called from `app.js`; from
`offline.js` with no socket) wires:

- **app startup** — one kick, to drain a queue left from a previous session.
- **`liveSocket.socket.onOpen`** — a LiveView (re)connect means a fresh session
  and CSRF token, the ideal moment to flush.
- **`window` `online`**, and **`visibilitychange` → visible**.
- **right after each `enqueue()`** — `quick_log.js` calls `requestFlush()`.
- **a 60 s `setInterval`** that exists *only while `pending` rows remain*
  (`syncIntervalToQueue()` starts/stops it off `trygg:queue-changed` and each
  run).
- **not** the Background Sync API — no iOS Safari support; the app is opened
  often enough that foreground flushing covers it.

### Retry backoff

`run()` swallows a `flush()` rejection (redirect / non-2xx / network throw) and
schedules a single retry timer at `30s → 2m → 10m` (`retryStep` capped at the
last bucket). A successful `flush()` calls `clearRetry()` and resets the step.
`sync.js` already bumps `attempts` on a `rejected` row.

### Rejected rows

`auto_sync.js` tracks the `rejected` count and shows a red body-level toast
(`"N offline entries couldn't sync"`) when it grows — so a validation failure
is visible even when the offline panel isn't on screen. The panel itself lists
each rejected row with a remove button.

### CSRF / stale session

The cached shell carries whatever CSRF token existed at cache time. The primary
flush path is a **fully-loaded LiveView page** — `startAutoSync({liveSocket})`
in `app.js` fires on `socket.onOpen`, when the token and session are known
good, and LiveView reloads the page itself when its token is stale. Flushing
from `offline.html` may `403`; that's fine — the rows are durable, backoff
holds them, and `offline.js` reloads into the live app ~2 s after `online`.

### Convergence

`Log.sync_entry/3` broadcasts, so the reconnected `DashboardLive` refreshes and
synced entries stream in. `sync.js` `queueDelete`s each `ok` row, so the panel's
pending list empties as results land; the Mount B overlay is dismissed on
reconnect and `offline.js` reloads — so there's no window where an optimistic
row and a streamed row show together.

---

## Phase 4 — running sleep timer + read cache  *(implemented)*

### Read cache — `snapshot` store

`db.js` bumps to `DB_VERSION` 2 and adds a `snapshot` store (keyPath
`childId`). `DashboardLive.refresh_summary/1` calls `push_offline_snapshot/4`,
which — only when `connected?` — `push_event`s `"offline:snapshot"` with:

- `running`: `[%{id, started_at}]` for each open sleep timer.
- `recent`: the last 8 entries as `%{type, at, text}`, `text` pre-formatted
  server-side (`"Bottle · 90 ml"`, `"Mixed diaper"`, `"Slept 1h 41m"`,
  `"Sleeping"`) so the panel stays dumb.

`offline_context.js`'s `mounted()` registers `this.handleEvent("offline:snapshot", …)`
→ `snapshotPut` → `trygg:snapshot-changed`. The panel renders a read-only
**"Recent — as of last sync"** list.

### Running sleep timer in the panel

`quick_log.js`'s sleep section is now stateful (`renderSleep`):

- **Nothing running** → **Start sleep** button + a `<details>` "Log a past
  sleep instead" (the old form).
- **A sleep running** → a live `Asleep 1h 23m` count (30 s tick) + **Stop
  sleep**. "Running" means either a local `pending` `sleep` row with no
  `endedAt`, or — if none locally and no `sleep_stop` queued — the snapshot's
  `running[0]`.
- **Start** → `enqueue("sleep", {startedAt: now, endedAt: null})`.
- **Stop** of a *local* running row → `queuePut` the same row with `endedAt`
  (one `client_id`, collapses to one entry on sync).
- **Stop** of a *snapshot* (server-started) timer → `enqueue("sleep_stop",
  {serverId, endedAt})`. `sync.js`'s `toEntry` sends `{client_id, server_id,
  ended_at}`; the controller routes any entry carrying `server_id` to
  `Log.sync_stop_timer/4`, which loads the entry (guarding `child_id`), clamps
  a future `ended_at`, and calls the existing `stop_timer/3`. Idempotent;
  `{:error, :not_found}` → `rejected`, never fatal to the batch.

### One running sleep per child

`Log.sync_entry/3` post-processes: if the write leaves an **open** sleep and
the child has other open sleeps (two caregivers, at least one offline),
`collapse_open_sleeps/1` keeps the earliest-started one, folds any `note` /
`data` from the rest into it, deletes the rest (`:deleted` broadcast each),
and re-broadcasts the survivor.

### Verified in a browser

Snapshot lands in IndexedDB (`recent` + `running`); the panel shows "Recent"
and a live "Asleep Nm" for a timer started online; **Stop sleep** offline →
`sleep_stop` row → syncs → server timer's `ended_at` set to the tap time;
**Start + Stop** both offline → one `client_id` row → one synced entry with
both timestamps; no stray open sleeps. `collapse_open_sleeps` / `sync_stop_timer`
also covered by ExUnit.

### Still deferred: offline photos

Would need the photo `Blob` in an IndexedDB store and a multipart upload
endpoint (the current upload goes through the LiveView channel), then a
`photo_key` patch on the entry. Self-contained; not needed for the night-shift
flow.

---

## Testing

No JS test runner in the repo, so automated coverage is ExUnit only:

- `Trygg.Log.sync_entry/3`: new insert; duplicate `client_id` idempotent
  (no second row, `:updated` broadcast); future `started_at` clamped;
  missing/garbage `client_id` rejected; non-caregiver raises; the
  "insert running sleep, later replace with `ended_at`" path; a `feeding` with
  `ended_at: null` stored instantaneous; **`collapse_open_sleeps`** — two
  overlapping open sleeps → the earliest kept, note merged, the other deleted.
- `Trygg.Log.sync_stop_timer/4`: stops a timer by server id; idempotent;
  `{:error, :not_found}` for another child's entry or a bad id.
- `TryggWeb.LogSyncController` (model on `push_subscription_controller_test.exs`):
  batch with one valid + one invalid → `200`, mixed `results`; re-POSTing a
  batch is a no-op (same row count); no session → redirect; other family's
  child → 404; a `server_id` entry stops a running timer; an unknown
  `server_id` → `rejected`, not fatal.

The JS has **no automated coverage** — the repo has no JS test runner. What
*was* verified in a browser against a dev server (fresh scratch DB, logged in
as the seed user):

- `OfflineContext` hook writes the child / units / tz / `canWrite` row to the
  `context` store on dashboard mount.
- `offline.html` loads `offline.js` and renders the quick-logger for that child
  (Bottle stepper, Diaper taps, Past-sleep, "Waiting to sync").
- Tapping **Poo** writes one `pending` `queue` row (UUID `clientId`, ISO
  `startedAt`, `data: {kind: "poo"}`).
- Flushing **from `offline.html` 403s** (no CSRF meta in the static file) and
  the row stays `pending` — exactly the documented fallback.
- Navigating into the live app, `startAutoSync` flushes it: `POST
  /c/1/log/entries` → `200`, row deleted, entry `#203` created with the same
  `client_id` and `started_at`, visible in the timeline.
- Re-POSTing that `client_id` returns `{status: "ok", id: 203}` with **no
  second row** (idempotency).
- A batch of one valid + one amountless feed → `200` with `["ok", "rejected"]`;
  the valid feed stored instantaneous (`ended_at == started_at`) from an
  explicit `ended_at: null`.
- **Phase 4:** the dashboard pushes a `snapshot` row (`recent` + `running`);
  the offline panel shows "Recent — as of last sync" and a live "Asleep Nm" for
  a timer started online; **Stop sleep** offline → `sleep_stop` row → sync →
  server timer #207's `ended_at` set to the tap time; **Start + Stop** both
  offline → one `client_id` row → one synced sleep entry with both timestamps,
  no stray open sleeps.

**Not verifiable in that environment:** service-worker registration is blocked
in the embedded browser, so the SW precache and the offline-navigation fallback
to `offline.html` still need a real browser. Run the full checklist below there:

1. `mix phx.server`, sign in, open a child's dashboard. Confirm (DevTools →
   Application → IndexedDB → `trygg-offline` → `context`) one row with the
   right `childId` / `unitSystem`.
2. DevTools → Network → **Offline**. Reload — the SW should serve
   `offline.html` and it should render the quick-logger for that child.
3. Log a bottle, a diaper, and a past sleep. Each shows in "Waiting to sync";
   the `queue` store has three `pending` rows.
4. Fully close the app, reopen still offline — rows persist, panel re-renders.
5. Network → **Online**. Within a few seconds the queue empties, and the three
   entries appear in the timeline (and for a second caregiver in another
   session). `offline.html` reloads into the live app.
6. Force a rejection: edit a queued row in DevTools to an invalid `data`, go
   online — it flips to `rejected`, the red toast shows, the row stays with a
   remove button.
7. Drop the socket while the app is open (DevTools offline, don't reload) —
   after ~1.5 s the overlay panel appears; restore the network — it dismisses
   and the queue drains.
8. Start a sleep in the live app, then go offline and open the panel — it shows
   **Asleep Nm** and **Stop sleep**; tap it, go online → the timer in the app
   stops at the tap time (not the sync time).
9. Offline, tap **Start sleep**, wait, tap **Stop sleep**, go online → exactly
   one sleep entry with the right span.

## Open decisions

1. Online taps still go straight through LiveView (smaller blast radius); the
   queue only fills while genuinely offline. Alternative: route every tap
   through Dexie for one uniform path.
2. Delete synced rows on ack (assumed) vs keep them briefly to show "✓ synced".
3. Rework `offline.html` (reuses the SW fallback) vs a dedicated `/quick` route.
4. `collapse_open_sleeps` keeps the earliest start and *deletes* the later
   duplicate(s). Alternative: keep both and let a caregiver merge by hand.
