// The offline quick-logger: a LiveView-free panel for capturing feeds,
// diapers and sleeps while the PWA has no connection. Entries are written
// straight to IndexedDB (`db.js`) and drained later by `sync.js`.
//
// Rendered in two places, both from bundles built off this module:
//   * `offline.js` — the whole screen when the app cold-starts offline
//     (`priv/static/offline.html`).
//   * the `OfflinePanel` hook — slid in over the live UI when the socket
//     drops while the app is already open.

import {queueAdd, queueAll, queuePut, queueDelete, contextAll, snapshotAll} from "./db"
import {requestFlush} from "./auto_sync"

const ML_PER_OZ = 29.5735295625
const TYPE_LABEL = {
  feeding: "Bottle",
  diaper: "Diaper",
  sleep: "Sleep",
  sleep_stop: "Sleep end",
  breastfeeding: "Breastfeeding",
  breastfeeding_stop: "Breastfeeding end",
}

// --- context / snapshot ------------------------------------------------

// The most recently mirrored row from a `getAll()`, or null. Normally there's
// only one child, but pick the freshest just in case.
function freshest(rows) {
  if (!rows || !rows.length) return null
  return rows.slice().sort((a, b) => (b.updatedAt || 0) - (a.updatedAt || 0))[0]
}

async function activeContext() {
  try {
    return freshest(await contextAll())
  } catch (_e) {
    return null
  }
}

async function snapshotFor(childId) {
  try {
    const rows = await snapshotAll()
    return rows.find((r) => r.childId === childId) || freshest(rows)
  } catch (_e) {
    return null
  }
}

// --- enqueue --------------------------------------------------------------

async function enqueue(ctx, type, {startedAt, endedAt, data, note, serverId} = {}) {
  const row = {
    clientId: crypto.randomUUID(),
    childId: ctx.childId,
    type,
    startedAt: type === "sleep_stop" ? null : startedAt || new Date().toISOString(),
    endedAt: endedAt || null,
    data: data || {},
    note: note || null,
    serverId: serverId ?? null,
    createdAt: Date.now(),
    attempts: 0,
    status: "pending",
  }
  await queueAdd(row)
  document.dispatchEvent(new CustomEvent("trygg:queue-changed"))
  requestFlush("enqueue") // best effort; offline this no-ops and the row waits
  return row
}

// --- tiny DOM helpers -------------------------------------------------

function el(tag, attrs = {}, children = []) {
  const node = document.createElement(tag)
  for (const [k, v] of Object.entries(attrs)) {
    if (k === "class") node.className = v
    else if (k === "text") node.textContent = v
    else if (v != null) node.setAttribute(k, v)
  }
  for (const child of [].concat(children)) if (child) node.append(child)
  return node
}

function localInputValue(date) {
  const pad = (n) => String(n).padStart(2, "0")
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  )
}

function relTime(ms) {
  const mins = Math.round((Date.now() - ms) / 60000)
  if (mins < 1) return "just now"
  if (mins < 60) return `${mins}m ago`
  return `${Math.round(mins / 60)}h ago`
}

function fmtElapsed(ms) {
  const mins = Math.max(0, Math.floor(ms / 60000))
  const h = Math.floor(mins / 60)
  const m = mins % 60
  return h ? `${h}h ${m}m` : `${m}m`
}

const STYLE = `
.tql { max-width: 26rem; margin: 0 auto; padding: 1.25rem; }
.tql h1 { font-size: 1.15rem; margin: 0 0 .25rem; }
.tql .tql-sub { opacity: .75; margin: 0 0 1.1rem; font-size: .9rem; }
.tql section { border: 1px solid color-mix(in srgb, currentColor 15%, transparent);
  border-radius: .9rem; padding: .9rem; margin-bottom: .8rem; }
.tql h2 { font-size: .78rem; text-transform: uppercase; letter-spacing: .04em;
  opacity: .7; margin: 0 0 .6rem; }
.tql button { font: inherit; cursor: pointer; border-radius: .7rem; min-height: 2.75rem;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent);
  background: transparent; color: inherit; padding: .6rem .8rem;
  touch-action: manipulation; -webkit-tap-highlight-color: transparent; }
.tql button:active { opacity: .6; }
.tql button.primary { background: color-mix(in srgb, currentColor 12%, transparent); font-weight: 600; }
.tql .grid3 { display: grid; grid-template-columns: repeat(3, 1fr); gap: .5rem; }
.tql .stepper { display: flex; align-items: center; gap: .6rem; justify-content: center; margin-bottom: .6rem; }
.tql .stepper output { font-size: 1.5rem; font-variant-numeric: tabular-nums; min-width: 4rem; text-align: center; }
.tql .stepper button { width: 3rem; }
.tql select, .tql input[type="datetime-local"] { font: inherit; padding: .5rem; border-radius: .6rem;
  width: 100%; box-sizing: border-box; background: transparent; color: inherit;
  border: 1px solid color-mix(in srgb, currentColor 25%, transparent); }
.tql label { display: block; font-size: .8rem; opacity: .7; margin: .5rem 0 .2rem; }
.tql .full { width: 100%; margin-top: .5rem; }
.tql details { margin-top: .6rem; }
.tql summary { cursor: pointer; font-size: .85rem; opacity: .75; padding: .5rem 0; }
.tql .elapsed { font-size: 1.6rem; font-variant-numeric: tabular-nums; margin: .1rem 0 .5rem; }
.tql .list { list-style: none; padding: 0; margin: 0; }
.tql .list li { display: flex; justify-content: space-between; align-items: center; gap: .5rem;
  padding: .45rem 0; font-size: .9rem;
  border-top: 1px solid color-mix(in srgb, currentColor 12%, transparent); }
.tql .list li:first-child { border-top: 0; }
.tql .list .when { opacity: .7; font-size: .8rem; white-space: nowrap; }
.tql .list .rejected { color: light-dark(#b3261e, #ff8a7a); opacity: 1; }
.tql .list .del { flex: 0 0 auto; min-width: 2.75rem; padding: .15rem .45rem; margin-left: .5rem; }
.tql .empty { opacity: .7; font-size: .85rem; }
.tql .toast { position: fixed; left: 50%; bottom: max(1.2rem, env(safe-area-inset-bottom)); transform: translateX(-50%);
  background: color-mix(in srgb, currentColor 88%, transparent); color: Canvas; padding: .55rem 1rem;
  border-radius: 999px; font-size: .85rem; opacity: 0; transition: opacity .2s; pointer-events: none; }
.tql .toast.show { opacity: 1; }
`

function ensureStyle() {
  if (!document.getElementById("tql-style")) {
    document.head.append(el("style", {id: "tql-style", text: STYLE}))
  }
}

// --- panel ----------------------------------------------------------

/**
 * Mount the quick-logger into `root`. `opts.onClose` adds a Close button
 * (used by the in-app panel). Returns `{ destroy, refresh }`.
 */
export function renderPanel(root, opts = {}) {
  ensureStyle()
  root.innerHTML = ""

  const wrap = el("div", {class: "tql"})
  const heading = el("div")
  const forms = el("div")
  const recentBox = el("div")
  const pendingList = el("ul", {class: "list"})
  const toast = el("div", {class: "toast"})
  wrap.append(
    heading,
    forms,
    recentBox,
    el("section", {}, [el("h2", {text: "Waiting to sync"}), pendingList])
  )
  if (opts.onClose) {
    const close = el("button", {type: "button", class: "full", text: "Close"})
    close.addEventListener("click", opts.onClose)
    wrap.append(close)
  }
  wrap.append(toast)
  root.append(wrap)

  let ctx = null
  let snap = null
  let timerBoxes = {}
  let timerIntervals = {}
  let toastTimer
  const flash = (msg) => {
    toast.textContent = msg
    toast.classList.add("show")
    clearTimeout(toastTimer)
    toastTimer = setTimeout(() => toast.classList.remove("show"), 1800)
  }

  async function myQueue() {
    try {
      const rows = await queueAll()
      return ctx ? rows.filter((r) => r.childId === ctx.childId) : rows
    } catch (_e) {
      return []
    }
  }

  async function renderPending() {
    const rows = await myQueue()
    pendingList.innerHTML = ""
    if (!rows.length) {
      pendingList.append(el("li", {class: "empty", text: "Nothing waiting to sync."}))
      return
    }
    for (const r of rows) {
      const label =
        (TYPE_LABEL[r.type] || r.type) +
        (r.type === "diaper" && r.data.kind ? ` · ${r.data.kind}` : "")
      const when = el("span", {
        class: r.status === "rejected" ? "when rejected" : "when",
        text: r.status === "rejected" ? "couldn't sync" : relTime(r.createdAt),
      })
      const del = el("button", {type: "button", class: "del", "aria-label": "Remove", text: "✕"})
      del.addEventListener("click", async () => {
        await queueDelete(r.clientId)
        document.dispatchEvent(new CustomEvent("trygg:queue-changed"))
      })
      pendingList.append(el("li", {}, [el("span", {text: label}), el("span", {}, [when, del])]))
    }
  }

  function renderRecent() {
    recentBox.innerHTML = ""
    const recent = (snap && snap.recent) || []
    if (!recent.length) return
    const ul = el("ul", {class: "list"})
    for (const r of recent) {
      ul.append(
        el("li", {}, [
          el("span", {text: r.text}),
          el("span", {class: "when", text: relTime(new Date(r.at).getTime())}),
        ])
      )
    }
    recentBox.append(el("section", {}, [el("h2", {text: "Recent — as of last sync"}), ul]))
  }

  function buildForms() {
    heading.innerHTML = ""
    forms.innerHTML = ""
    Object.values(timerIntervals).forEach(clearInterval)
    timerIntervals = {}

    if (!ctx) {
      heading.append(
        el("h1", {text: "You're offline"}),
        el("p", {
          class: "tql-sub",
          text: "Open Trygg once while online and it'll remember this baby — then you can log offline next time.",
        })
      )
      return
    }

    heading.append(
      el("h1", {text: `Log for ${ctx.childName}`}),
      el("p", {class: "tql-sub", text: "Saved on this device — syncs when you're back online."})
    )

    // Only the trackers this child's Home shows. Contexts mirrored before the
    // layout was configurable have no list and offer everything.
    const tracked = ctx.trackedTypes || ["feeding", "diaper", "sleep", "breastfeeding"]
    timerBoxes = Object.fromEntries(
      ["sleep", "breastfeeding"]
        .filter((type) => tracked.includes(type))
        .map((type) => [type, el("section", {})])
    )
    if (tracked.includes("feeding")) forms.append(bottleSection())
    if (tracked.includes("diaper")) forms.append(diaperSection())
    Object.entries(timerBoxes).forEach(([type, box]) => {
      forms.append(box)
      renderTimer(type, box)
    })
  }

  function bottleSection() {
    const unit = ctx.unitSystem === "imperial" ? "oz" : "ml"
    const step = unit === "oz" ? 0.5 : 10
    let amount = 0
    const out = el("output", {text: "0"})
    const set = (v) => {
      amount = Math.max(0, Math.round(v * 100) / 100)
      out.textContent = String(amount)
    }
    const minus = el("button", {type: "button", text: "−"})
    const plus = el("button", {type: "button", text: "+"})
    minus.addEventListener("click", () => set(amount - step))
    plus.addEventListener("click", () => set(amount + step))
    const contents = el("select", {}, [
      el("option", {value: "", text: "Contents (optional)"}),
      el("option", {value: "formula", text: "Formula"}),
      el("option", {value: "expressed", text: "Expressed"}),
      el("option", {value: "donor", text: "Donor"}),
    ])
    const save = el("button", {type: "button", class: "primary full", text: "Save bottle"})
    save.addEventListener("click", async () => {
      if (!amount) return flash("Pick an amount first")
      const now = new Date().toISOString()
      const data = {amount_ml: unit === "oz" ? amount * ML_PER_OZ : amount}
      if (contents.value) data.bottle_contents = contents.value
      await enqueue(ctx, "feeding", {startedAt: now, endedAt: now, data})
      set(0)
      flash("Bottle saved")
    })
    return el("section", {}, [
      el("h2", {text: `Bottle (${unit})`}),
      el("div", {class: "stepper"}, [minus, out, plus]),
      contents,
      save,
    ])
  }

  function diaperSection() {
    const btns = ["pee", "poo", "mixed"].map((kind) => {
      const b = el("button", {type: "button", text: kind[0].toUpperCase() + kind.slice(1)})
      b.addEventListener("click", async () => {
        await enqueue(ctx, "diaper", {data: {kind}})
        flash(`${b.textContent} diaper saved`)
      })
      return b
    })
    return el("section", {}, [el("h2", {text: "Diaper"}), el("div", {class: "grid3"}, btns)])
  }

  // Sleep and breastfeeding are independent timer types, both of which may be
  // started on this device or stopped from a server snapshot.
  async function renderTimer(type, box) {
    if (timerIntervals[type]) clearInterval(timerIntervals[type])
    box.innerHTML = ""
    const breastfeeding = type === "breastfeeding"
    const label = breastfeeding ? "Breastfeeding" : "Sleep"
    const title = breastfeeding ? "How did they eat?" : "Stop sleep"
    box.append(el("h2", {text: label}))

    const rows = await myQueue()
    const localRun = rows.find(
      (r) => r.type === type && !r.endedAt && r.status === "pending"
    )
    const stoppedLocally = rows.some((r) => r.type === `${type}_stop`)
    const serverRun =
      !localRun && !stoppedLocally && snap?.running?.find((entry) => entry.type === type)

    if (localRun || serverRun) {
      const since = new Date(localRun ? localRun.startedAt : serverRun.started_at).getTime()
      const elapsed = el("div", {class: "elapsed"})
      const tick = () =>
        (elapsed.textContent = `${breastfeeding ? "Feeding" : "Asleep"} ${fmtElapsed(Date.now() - since)}`)
      tick()
      timerIntervals[type] = setInterval(tick, 30000)

      const stop = el("button", {
        type: "button",
        class: "primary full",
        text: breastfeeding ? "Stop breastfeeding" : "Stop sleep",
      })
      stop.addEventListener("click", async () => {
        const nowISO = new Date().toISOString()
        const data = {}
        if (breastfeeding) {
          const pattern = window.prompt(`${title} (constant, on and off, barely; leave blank to skip)`)
          if (pattern && !["constant", "on and off", "barely"].includes(pattern)) {
            return flash("Choose constant, on and off, barely or leave blank")
          }
          if (pattern) data.pattern = pattern
        }
        if (localRun) {
          await queuePut({...localRun, endedAt: nowISO, data: {...localRun.data, ...data}})
          document.dispatchEvent(new CustomEvent("trygg:queue-changed"))
          requestFlush("enqueue")
        } else {
          await enqueue(ctx, `${type}_stop`, {serverId: serverRun.id, endedAt: nowISO, data})
        }
        flash(`${label} saved`)
      })
      box.append(elapsed, stop)
      return
    }

    const start = el("button", {
      type: "button",
      class: "primary full",
      text: breastfeeding ? "Start breastfeeding" : "Start sleep",
    })
    start.addEventListener("click", async () => {
      await enqueue(ctx, type, {startedAt: new Date().toISOString(), endedAt: null})
      flash(`${label} started`)
    })

    if (breastfeeding) {
      box.append(start)
      return
    }

    const now = new Date()
    const s = el("input", {
      type: "datetime-local",
      value: localInputValue(new Date(now.getTime() - 3600 * 1000)),
    })
    const e = el("input", {type: "datetime-local", value: localInputValue(now)})
    const savePast = el("button", {type: "button", class: "full", text: "Save past sleep"})
    savePast.addEventListener("click", async () => {
      const from = new Date(s.value)
      const to = new Date(e.value)
      if (!(from < to)) return flash("End must be after start")
      await enqueue(ctx, type, {startedAt: from.toISOString(), endedAt: to.toISOString()})
      flash("Sleep saved")
    })

    box.append(
      start,
      el("details", {}, [
        el("summary", {text: "Log a past sleep instead"}),
        el("label", {text: "Fell asleep"}),
        s,
        el("label", {text: "Woke up"}),
        e,
        savePast,
      ])
    )
  }

  const rerender = () => {
    buildForms()
    renderRecent()
    renderPending()
  }

  const onQueueChanged = () => {
    Object.entries(timerBoxes).forEach(([type, box]) => {
      if (box.isConnected) renderTimer(type, box)
    })
    renderPending()
  }
  const onSnapshotChanged = () => load()
  document.addEventListener("trygg:queue-changed", onQueueChanged)
  document.addEventListener("trygg:snapshot-changed", onSnapshotChanged)

  function load() {
    return activeContext().then(async (c) => {
      ctx = c
      snap = c ? await snapshotFor(c.childId) : null
      rerender()
    })
  }
  load()

  return {
    destroy() {
      Object.values(timerIntervals).forEach(clearInterval)
      document.removeEventListener("trygg:queue-changed", onQueueChanged)
      document.removeEventListener("trygg:snapshot-changed", onSnapshotChanged)
      root.innerHTML = ""
    },
    refresh: load,
  }
}
