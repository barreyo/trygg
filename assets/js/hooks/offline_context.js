// Mirrors the essentials of the current LiveView screen — which child, its
// name, the caregiver's unit system and write access — into IndexedDB, so the
// LiveView-free offline screen (`offline.js` / the `OfflinePanel` hook) knows
// what it is logging for. Also relays the dashboard's `offline:snapshot`
// push (last few entries + any running sleep) into the `snapshot` store so the
// offline screen isn't blind. The only bridge from the live app to the queue.
//
// Attach to an element that carries the context as `data-*` attributes and
// re-renders when the child changes.

import {contextPut, snapshotPut} from "../offline/db"

function persist(el) {
  const {childId, childName, unitSystem, canWrite, tz} = el.dataset
  if (!childId || canWrite !== "true") return

  contextPut({
    childId: Number(childId),
    childName: childName || "your baby",
    unitSystem: unitSystem === "imperial" ? "imperial" : "metric",
    canWrite: true,
    tz: tz || "UTC",
    updatedAt: Date.now(),
  }).catch(() => {})
}

export default {
  mounted() {
    persist(this.el)

    this.handleEvent("offline:snapshot", (snap) => {
      const childId = Number(this.el.dataset.childId)
      if (!childId) return
      snapshotPut({childId, ...snap, updatedAt: Date.now()})
        .then(() => document.dispatchEvent(new CustomEvent("trygg:snapshot-changed")))
        .catch(() => {})
    })
  },
  updated() {
    persist(this.el)
  },
}
