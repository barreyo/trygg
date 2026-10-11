// Clears a flash toast on its own after `data-dismiss-after` milliseconds.
//
// A draining bar along the toast's edge (`.flash-timer`, see app.css) shows how
// long is left. The dismissal is the toast's own tap action, so it plays the
// same exit transition and tells the server to drop the flash. The countdown
// holds while a pointer is over the toast (the bar holds with it, via CSS), and
// restarts when the same toast is re-used for a new message.

const AutoDismiss = {
  mounted() {
    this.remaining = this.total()
    this.onEnter = () => this.pause()
    this.onLeave = () => this.start()
    this.el.addEventListener("pointerenter", this.onEnter)
    this.el.addEventListener("pointerleave", this.onLeave)
    this.start()
  },

  // A new message landed in the same element: give it its full time again.
  updated() {
    this.remaining = this.total()
    this.restartBar()
    this.start()
  },

  destroyed() {
    clearTimeout(this.timer)
    this.el.removeEventListener("pointerenter", this.onEnter)
    this.el.removeEventListener("pointerleave", this.onLeave)
  },

  total() {
    return parseInt(this.el.dataset.dismissAfter, 10) || 4000
  },

  start() {
    clearTimeout(this.timer)
    this.startedAt = Date.now()
    this.timer = setTimeout(() => this.dismiss(), this.remaining)
  },

  pause() {
    clearTimeout(this.timer)
    this.remaining = Math.max(0, this.remaining - (Date.now() - this.startedAt))
  },

  dismiss() {
    // Same as tapping it: clear the flash on the server and hide with a transition.
    window.liveSocket.execJS(this.el, this.el.getAttribute("phx-click"))
  },

  restartBar() {
    const bar = this.el.querySelector("[data-flash-timer]")
    if (!bar) return
    bar.style.animation = "none"
    void bar.offsetWidth
    bar.style.animation = ""
  },
}

export default AutoDismiss
