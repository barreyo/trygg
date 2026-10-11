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
//
// Physics (see assets/js/spring.js): the page follows the finger with
// progressive resistance (a rubber band, never a hard stop), and every settle
// is a spring that starts from the live position and carries the finger's
// release velocity. Grabbing the page again mid-settle picks up from where it
// is, rather than jumping.
import {spring, rubberband, unrubberband, VelocityTracker} from "../spring"
import {tick} from "../haptics"

const THRESHOLD = 64 // px of pull past which release triggers a refresh
const BAND = 150 // the rubber band's soft limit: the pull creeps towards it but never reaches it
const BAND_CONSTANT = 0.9
const FAILSAFE_MS = 4000 // release the spinner even if the server never replies

const PullToRefresh = {
  mounted() {
    this.target = document.querySelector("main")
    this.indicator = this.el.querySelector("[data-ptr-indicator]")
    this.spinner = this.el.querySelector("[data-ptr-spinner]")
    if (!this.target) return

    this.startY = null
    this.baseTravel = 0 // finger travel already "spent" when a gesture picks up a moving page
    this.pull = 0
    this.anim = null
    this.refreshing = false
    this.tracker = new VelocityTracker()

    this.onStart = (e) => {
      if (this.refreshing || e.touches.length !== 1) return
      // Only arm at the very top of the page; otherwise this is a normal scroll.
      if (window.scrollY > 0) return

      // Grabbed mid-settle: freeze the spring where it is and carry on from there.
      if (this.anim) {
        this.anim.stop()
        this.pull = this.anim.value
        this.anim = null
      }
      this.baseTravel = unrubberband(this.pull, BAND, BAND_CONSTANT)
      this.startY = e.touches[0].clientY
      this.tracker.reset()
      this.tracker.add(this.pull)
    }

    this.onMove = (e) => {
      if (this.startY === null) return
      const dy = this.baseTravel + (e.touches[0].clientY - this.startY)
      // Finger moved up (page scroll) or momentum carried us off the top: bail
      // and let the browser scroll normally.
      if (dy <= 0 || window.scrollY > 0) {
        this.disarm()
        return
      }
      const wasArmed = this.pull >= THRESHOLD
      this.pull = rubberband(dy, BAND, BAND_CONSTANT)
      // A tick as the pull crosses the point where letting go will refresh.
      if (!wasArmed && this.pull >= THRESHOLD) tick(8)
      this.tracker.add(this.pull)
      // We own the gesture now — stop the page from scrolling under us.
      if (e.cancelable) e.preventDefault()
      this.setOffset(this.pull)
    }

    this.onEnd = () => {
      if (this.startY === null) return
      const velocity = this.tracker.velocity()
      this.startY = null
      // A fast flick back up cancels even a deep pull: the finger changed its mind.
      if (this.pull >= THRESHOLD && velocity > -600) this.trigger(velocity)
      else this.animateBack(velocity)
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
    if (this.anim) this.anim.stop()
    // Navigated away mid-pull: don't leave <main> translated for the next page.
    this.setOffset(0)
  },

  setOffset(px) {
    this.target.style.transform = px ? `translateY(${px}px)` : ""
    if (this.indicator) {
      const p = Math.min(px / THRESHOLD, 1)
      this.indicator.style.opacity = String(p)
      this.indicator.style.transform = `translateY(${px}px)`
    }
    if (this.spinner && !this.refreshing) {
      // The arrow turns as you pull and gives a little pop once release will refresh.
      const turn = Math.min(px / THRESHOLD, 1) * 270
      const pop = px >= THRESHOLD ? 1.12 : 1
      this.spinner.style.transform = px ? `rotate(${turn}deg) scale(${pop})` : ""
    }
  },

  // Give up the gesture mid-drag: snap back so the page scrolls immediately.
  disarm() {
    this.startY = null
    this.pull = 0
    if (this.anim) this.anim.stop()
    this.anim = null
    this.setOffset(0)
  },

  // Spring the page to `target`, starting from where it is now with the
  // finger's release velocity.
  moveTo(target, velocity, damping, onDone) {
    if (this.anim) this.anim.stop()
    this.anim = spring({
      from: this.pull,
      to: target,
      velocity,
      response: 0.32,
      damping,
      onUpdate: (v) => {
        this.pull = v
        this.setOffset(v)
      },
      onDone: () => {
        this.anim = null
        if (onDone) onDone()
      },
    })
  },

  animateBack(velocity = 0) {
    this.moveTo(0, velocity, 1)
  },

  trigger(velocity) {
    this.refreshing = true
    // Rest at the threshold while the refresh runs.
    this.moveTo(THRESHOLD, velocity, 0.85)
    if (this.spinner) {
      this.spinner.style.transform = ""
      this.spinner.classList.add("motion-safe:animate-spin")
    }

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
}

export default PullToRefresh
