// Decides *when* to drain the offline queue. `sync.js` owns the transport;
// this module owns the triggers, the retry backoff and a periodic safety net.
//
// Triggers: app startup, LiveView (re)connect, `window` online,
// `visibilitychange` to visible, and right after an `enqueue()`. Plus a 60s
// interval that runs only while rows are still waiting. Deliberately *not* the
// Background Sync API — iOS Safari doesn't support it, and the app is opened
// often enough that foreground flushing covers it.

import {flush} from "./sync"
import {queueAll} from "./db"

const BACKOFF_MS = [30_000, 120_000, 600_000]
const INTERVAL_MS = 60_000

let retryTimer = null
let retryStep = 0
let intervalTimer = null
let started = false

async function pendingCount() {
  try {
    return (await queueAll()).filter((r) => r.status === "pending").length
  } catch (_e) {
    return 0
  }
}

async function rejectedCount() {
  try {
    return (await queueAll()).filter((r) => r.status === "rejected").length
  } catch (_e) {
    return 0
  }
}

function clearRetry() {
  if (retryTimer) clearTimeout(retryTimer)
  retryTimer = null
  retryStep = 0
}

function scheduleRetry() {
  if (retryTimer) return
  const delay = BACKOFF_MS[Math.min(retryStep, BACKOFF_MS.length - 1)]
  retryTimer = setTimeout(() => {
    retryTimer = null
    run("retry")
  }, delay)
}

async function syncIntervalToQueue() {
  const pending = await pendingCount()
  if (pending && !intervalTimer) {
    intervalTimer = setInterval(() => run("interval"), INTERVAL_MS)
  } else if (!pending && intervalTimer) {
    clearInterval(intervalTimer)
    intervalTimer = null
  }
}

let lastRejectedSeen = 0

async function surfaceRejected() {
  const count = await rejectedCount()
  if (count > lastRejectedSeen) toast(`${count} offline ${count === 1 ? "entry" : "entries"} couldn't sync`)
  lastRejectedSeen = count
}

let toastEl
let toastTimer
function toast(msg) {
  if (!toastEl) {
    toastEl = document.createElement("div")
    Object.assign(toastEl.style, {
      position: "fixed",
      left: "50%",
      bottom: "1.2rem",
      transform: "translateX(-50%)",
      zIndex: "10000",
      background: "#c0392b",
      color: "#fff",
      padding: ".55rem 1rem",
      borderRadius: "999px",
      font: "500 .85rem system-ui, sans-serif",
      boxShadow: "0 2px 10px rgba(0,0,0,.25)",
      opacity: "0",
      transition: "opacity .2s",
      pointerEvents: "none",
    })
    document.body.append(toastEl)
  }
  toastEl.textContent = msg
  toastEl.style.opacity = "1"
  clearTimeout(toastTimer)
  toastTimer = setTimeout(() => (toastEl.style.opacity = "0"), 4000)
}

async function run(_reason) {
  if (!navigator.onLine) return
  try {
    await flush()
    clearRetry()
  } catch (_e) {
    retryStep += 1
    scheduleRetry()
  }
  await surfaceRejected()
  await syncIntervalToQueue()
}

/** Ask for a flush now (used right after an enqueue). Safe to spam. */
export function requestFlush(reason = "manual") {
  run(reason)
}

/**
 * Wire the triggers. Call once. Pass the app's `liveSocket` in the running
 * app so a socket (re)connect — which means a fresh session and CSRF token —
 * kicks a flush; omit it in the offline shell.
 */
export function startAutoSync({liveSocket} = {}) {
  if (started) return
  started = true

  window.addEventListener("online", () => run("online"))
  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) run("visible")
  })
  document.addEventListener("trygg:queue-changed", () => syncIntervalToQueue())

  if (liveSocket && liveSocket.socket && liveSocket.socket.onOpen) {
    liveSocket.socket.onOpen(() => run("socket-open"))
  }

  run("startup")
}
