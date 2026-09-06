// Draining the offline queue (`db.js`) to the server.
//
// Phase 2 ships the transport: a single-flight POST of the pending rows,
// grouped by child, to `POST /c/:id/log/entries`. Phase 3 layers on the
// trigger wiring (reconnect / `online` / `visibilitychange`), retry backoff
// and a periodic safety net — for now `flush()` is called opportunistically
// right after each `enqueue()` and simply rejects (leaving rows in place)
// whenever the network is unreachable.

import {queueAll, queuePut, queueDelete} from "./db"

let inFlight = null

function csrfToken() {
  const meta = document.querySelector("meta[name='csrf-token']")
  return meta ? meta.getAttribute("content") : ""
}

function groupByChild(rows) {
  const groups = new Map()
  for (const row of rows) {
    if (!groups.has(row.childId)) groups.set(row.childId, [])
    groups.get(row.childId).push(row)
  }
  return groups
}

function toEntry(row) {
  // "Stop this running timer" — keyed by the timer's server id, no client_id
  // payload beyond the queue key the server echoes back.
  if (row.type === "sleep_stop") {
    return {client_id: row.clientId, server_id: row.serverId, ended_at: row.endedAt}
  }

  return {
    client_id: row.clientId,
    type: row.type,
    started_at: row.startedAt,
    ended_at: row.endedAt,
    data: row.data || {},
    note: row.note,
  }
}

async function postChild(childId, rows) {
  const res = await fetch(`/c/${childId}/log/entries`, {
    method: "POST",
    credentials: "same-origin",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
    body: JSON.stringify({entries: rows.map(toEntry)}),
  })

  // A redirect to the log-in page (dead session) or any non-2xx: leave the
  // whole group queued and try again later.
  if (res.redirected || !res.ok) {
    throw new Error(`sync failed: ${res.status}`)
  }

  const {results} = await res.json()
  const byId = new Map((results || []).map((r) => [r.client_id, r]))

  for (const row of rows) {
    const result = byId.get(row.clientId)
    if (!result) continue
    if (result.status === "ok") {
      await queueDelete(row.clientId)
    } else if (result.status === "rejected") {
      // A validation failure won't pass on a retry — park it for the user
      // to remove rather than looping forever.
      await queuePut({...row, status: "rejected", attempts: (row.attempts || 0) + 1})
    }
  }
}

/**
 * Push every pending row to the server. Single-flight: concurrent callers
 * share the one in-progress run. Resolves when the attempt finishes (some
 * rows may remain queued); rejects if a group could not be delivered.
 */
export function flush() {
  if (inFlight) return inFlight

  inFlight = (async () => {
    const rows = (await queueAll()).filter((r) => r.status === "pending")
    if (!rows.length) return

    let failure = null
    for (const [childId, group] of groupByChild(rows)) {
      try {
        await postChild(childId, group)
      } catch (err) {
        failure = err
      }
    }
    document.dispatchEvent(new CustomEvent("trygg:queue-changed"))
    if (failure) throw failure
  })().finally(() => {
    inFlight = null
  })

  return inFlight
}
