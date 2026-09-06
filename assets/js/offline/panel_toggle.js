// Mount point B: reveal the offline quick-logger over the live UI when the
// connection drops while the app is already open (a night-feed wifi blip is
// the common case). Driven from app.js with the app's LiveSocket.
//
// Kept deliberately conservative — the panel only appears when the browser
// itself reports being offline, so a brief socket reconnect during a deploy
// doesn't flash it up. Draining the queue is auto_sync.js's job, not this
// module's; here we only show and hide the overlay.

import {renderPanel} from "./quick_log"

export function installOfflinePanel(liveSocket) {
  let overlay
  let handle

  function ensureOverlay() {
    if (overlay) return overlay
    overlay = document.createElement("div")
    overlay.id = "offline-panel"
    overlay.hidden = true
    Object.assign(overlay.style, {
      position: "fixed",
      inset: "0",
      zIndex: "9999",
      overflowY: "auto",
      background: "Canvas",
    })
    document.body.append(overlay)
    return overlay
  }

  function show() {
    ensureOverlay()
    if (!overlay.hidden) return
    handle = renderPanel(overlay, {onClose: hide})
    overlay.hidden = false
  }

  function hide() {
    if (!overlay || overlay.hidden) return
    handle && handle.destroy()
    handle = null
    overlay.hidden = true
  }

  function onDrop() {
    // Give a same-network reconnect a moment before intruding.
    setTimeout(() => {
      if (!navigator.onLine && !liveSocket.isConnected()) show()
    }, 1500)
  }

  function onBack() {
    if (liveSocket.isConnected()) hide()
  }

  liveSocket.socket.onClose(onDrop)
  liveSocket.socket.onOpen(onBack)
  window.addEventListener("offline", onDrop)
  window.addEventListener("online", onBack)
}
