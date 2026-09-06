// Entry point for `priv/static/offline.html` — the screen the service worker
// serves when the PWA cold-starts with no connection. Mounts the offline
// quick-logger and wires the sync triggers; once the network is back it drains
// the queue and reloads so the live app takes over.
//
// Built as its own esbuild bundle (see config/config.exs) and loaded from
// offline.html by a literal, undigested path so it survives `mix phx.digest`
// and can be precached by the service worker at a stable URL.

import {renderPanel} from "./offline/quick_log"
import {startAutoSync} from "./offline/auto_sync"

const mount = document.getElementById("offline-app")
if (mount) renderPanel(mount)

// No LiveSocket here — auto_sync still flushes on `online` / `visibilitychange`
// / its 60s net.
startAutoSync()

// Hand back to the live app shortly after the network returns; the flush above
// has had a chance to run, and anything left (a rejected row) is shown by the
// in-app panel.
window.addEventListener("online", () => {
  setTimeout(() => {
    if (navigator.onLine) location.reload()
  }, 2000)
})
