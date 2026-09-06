// Custom pull-to-refresh for the installed PWA.
//
// A standalone PWA has no browser chrome, so the platform's native
// pull-to-refresh gesture is gone — and `overscroll-behavior-y: none` in
// app.css disables it in a plain browser tab too. This hook re-adds it: drag
// down from the very top of the page to re-sync, which pushes a `refresh`
// event to the LiveView. LiveView already streams changes over the socket, so
// this is mostly a "did I miss anything?" nudge; the server's empty reply
// releases the spinner. If the socket is down we fall back to a full reload.
//
// The hook element is an inert sentinel (`display: contents`) that only
// carries `[data-ptr-indicator]` (with a `[data-ptr-spinner]` inside). The
// gesture is measured on, and the pull translates, the page's <main> element.
const THRESHOLD = 64 // px of pull past which release triggers a refresh
const MAX_PULL = 96 // px <main> travels at most
const RESISTANCE = 0.5 // finger-travel to pull-distance ratio
const FAILSAFE_MS = 4000 // release the spinner even if the server never replies

const PullToRefresh = {
  mounted() {
    this.target = document.querySelector("main")
    this.indicator = this.el.querySelector("[data-ptr-indicator]")
    this.spinner = this.el.querySelector("[data-ptr-spinner]")
    if (!this.target) return

    this.startY = null
    this.pull = 0
    this.refreshing = false

    this.onStart = (e) => {
      if (this.refreshing || e.touches.length !== 1) return
      // Only arm at the very top of the page; otherwise this is a normal scroll.
      if (window.scrollY > 0) return
      this.startY = e.touches[0].clientY
      this.pull = 0
    }

    this.onMove = (e) => {
      if (this.startY === null) return
      const dy = e.touches[0].clientY - this.startY
      // Finger moved up (page scroll) or momentum carried us off the top: bail
      // and let the browser scroll normally.
      if (dy <= 0 || window.scrollY > 0) {
        this.disarm()
        return
      }
      this.pull = Math.min(dy * RESISTANCE, MAX_PULL)
      // We own the gesture now — stop the page from scrolling under us.
      if (e.cancelable) e.preventDefault()
      this.setOffset(this.pull)
    }

    this.onEnd = () => {
      if (this.startY === null) return
      const triggered = this.pull >= THRESHOLD
      this.startY = null
      if (triggered) this.trigger()
      else this.animateBack()
    }

    // touchmove needs `passive: false` so preventDefault() can hold the scroll.
    this.target.addEventListener("touchstart", this.onStart, {passive: true})
    this.target.addEventListener("touchmove", this.onMove, {passive: false})
    this.target.addEventListener("touchend", this.onEnd, {passive: true})
    this.target.addEventListener("touchcancel", this.onEnd, {passive: true})
  },

  destroyed() {
    if (!this.target) return
    this.target.removeEventListener("touchstart", this.onStart)
    this.target.removeEventListener("touchmove", this.onMove)
    this.target.removeEventListener("touchend", this.onEnd)
    this.target.removeEventListener("touchcancel", this.onEnd)
    clearTimeout(this.failsafe)
    // Navigated away mid-pull: don't leave <main> translated for the next page.
    this.setTransition("")
    this.setOffset(0)
  },

  setOffset(px) {
    this.target.style.transform = px ? `translateY(${px}px)` : ""
    if (this.indicator) {
      const p = Math.min(px / THRESHOLD, 1)
      this.indicator.style.opacity = String(p)
      this.indicator.style.transform = `translateY(${px}px)`
    }
  },

  // Give up the gesture mid-drag: snap back with no transition so the page
  // scrolls immediately.
  disarm() {
    this.startY = null
    this.pull = 0
    this.setTransition("")
    this.setOffset(0)
  },

  animateBack() {
    this.pull = 0
    this.setTransition("transform .2s ease")
    this.setOffset(0)
    setTimeout(() => this.setTransition(""), 220)
  },

  trigger() {
    this.refreshing = true
    // Rest at the threshold while the refresh runs.
    this.setTransition("transform .2s ease")
    this.setOffset(THRESHOLD)
    if (this.spinner) this.spinner.classList.add("motion-safe:animate-spin")

    if (window.liveSocket && window.liveSocket.isConnected()) {
      this.pushEvent("refresh", {}, () => this.finish())
      this.failsafe = setTimeout(() => this.finish(), FAILSAFE_MS)
    } else {
      window.location.reload()
    }
  },

  finish() {
    clearTimeout(this.failsafe)
    if (!this.refreshing) return
    this.refreshing = false
    if (this.spinner) this.spinner.classList.remove("motion-safe:animate-spin")
    this.animateBack()
  },

  setTransition(value) {
    this.target.style.transition = value
    if (this.indicator) this.indicator.style.transition = value
  },
}

export default PullToRefresh
