// Swipe left/right anywhere on a child-scoped page to jump to the next/
// previous child, instead of opening the switcher dropdown every time. The
// hook lives directly on <main> (see `TryggWeb.Layouts.app/1`) and is only
// attached when there are 2+ children to switch between.
//
// A swipe drags <main> horizontally with progressive resistance, like a
// carousel, while a small chip for the child you'd land on
// (`#child-swipe-peek-prev` / `-next`, also rendered by the layout) slides in
// from that edge — so mid-drag you already see who you're about to switch to.
// Release hands off to the *existing* child-switcher link
// (`#child-switcher [role="menuitem"]`) by clicking it — so live navigation,
// aria-current, and the href itself all stay driven by the server-rendered
// menu instead of being duplicated here.
//
// Physics (see assets/js/spring.js):
//  * The page follows the finger with a rubber band: more resistance the
//    further it goes, never a hard stop.
//  * Release is judged by the finger's velocity as well as the distance: a
//    quick flick in the drag direction commits from a short drag, a quick flick
//    back cancels even a long one.
//  * Every settle is a spring that starts from the live position and carries the
//    release velocity, so grabbing the page again mid-settle picks up from where
//    it is.
//  * Continuity: the page you swiped away slides off to one side and the next
//    one slides in from the other (`playEnter`).
//
// The first time this hook ever mounts on a device, it also plays a brief,
// unprompted preview of the gesture (a small nudge + peek) so the feature is
// discoverable without a tutorial. It never plays again after that (tracked
// in localStorage) and is skipped entirely under reduced-motion.
import {spring, rubberband, unrubberband, VelocityTracker} from "../spring"
import {tick} from "../haptics"

const THRESHOLD = 72 // px of drag past which release switches child
const BAND = 300 // the rubber band's soft limit
const BAND_CONSTANT = 0.7
const DIRECTION_LOCK = 10 // px of movement before we commit to swipe vs scroll
const FLICK = 300 // px/s: faster than this and the direction of travel decides, not the distance
const FLICK_MIN_DRAG = 16 // px: a flick still has to have moved a little to count
const EDGE = 20 // px: leave touches this close to the screen edge to the OS back gesture
const SLIDE_OUT = 140 // px the page slides to when a swipe commits

const PEEK_OFFSCREEN = 28 // extra px a peek chip sits beyond its resting spot while hidden

const HINT_KEY = "trygg:child-swipe-hint-seen"
const HINT_DELAY = 900 // ms after mount before the one-time hint plays
const HINT_HOLD = 650 // ms the hint's peek stays out before easing back

// Set when a swipe commits so the page that mounts next knows which way to
// slide in from; stale after a couple of seconds (a slow connection, or the
// user tapped somewhere else meanwhile).
const ENTER_KEY = "trygg:child-swipe-enter"
const ENTER_TTL = 2500
const ENTER_FROM = 56 // px the incoming page starts offset by

const ChildSwipe = {
  mounted() {
    this.startX = null
    this.startY = null
    this.baseTravel = 0 // finger travel already "spent" when a gesture picks up a moving page
    this.offset = 0
    this.anim = null
    this.peeking = true // peek chips follow the drag (off while the page slides in)
    this.entering = false // sliding in after a swipe: opacity follows the offset
    this.dragging = false // committed to a horizontal swipe
    this.locked = false // committed to letting a vertical scroll through
    this.tracker = new VelocityTracker()

    this.prevPeek = document.getElementById("child-swipe-peek-prev")
    this.nextPeek = document.getElementById("child-swipe-peek-next")

    this.onStart = (e) => {
      if (e.touches.length !== 1) return
      clearTimeout(this.hintTimer)
      clearTimeout(this.hintHoldTimer)
      const x = e.touches[0].clientX
      if (x < EDGE || x > window.innerWidth - EDGE) return
      // A horizontally scrollable ancestor (charts, timelines) owns its own
      // gesture; don't steal it.
      if (this.withinHorizontalScroller(e.target)) return

      // Grabbed mid-settle (or mid-hint): freeze the spring where it is and
      // carry on from there.
      if (this.anim) {
        this.anim.stop()
        this.offset = this.anim.value
        this.anim = null
      }
      this.peeking = true
      this.entering = false
      this.baseTravel = unrubberband(this.offset, BAND, BAND_CONSTANT)
      this.startX = x
      this.startY = e.touches[0].clientY
      this.dragging = Math.abs(this.offset) > 0.5 // already moving: it's a swipe
      this.locked = false
      this.tracker.reset()
      this.tracker.add(this.offset)
    }

    this.onMove = (e) => {
      if (this.startX === null) return
      const dx = e.touches[0].clientX - this.startX
      const dy = e.touches[0].clientY - this.startY

      if (!this.dragging && !this.locked) {
        if (Math.abs(dx) < DIRECTION_LOCK && Math.abs(dy) < DIRECTION_LOCK) return
        if (Math.abs(dy) >= Math.abs(dx)) {
          this.locked = true // vertical scroll, let it through
          return
        }
        this.dragging = true
      }
      if (!this.dragging) return

      if (e.cancelable) e.preventDefault()
      this.setOffset(rubberband(this.baseTravel + dx, BAND, BAND_CONSTANT))
      this.tracker.add(this.offset)
    }

    this.onEnd = () => {
      this.startX = null
      if (!this.dragging) return
      this.dragging = false

      const velocity = this.tracker.velocity()
      const moved = Math.abs(this.offset)
      const flicking = Math.abs(velocity) > FLICK
      const withDrag = Math.sign(velocity) === Math.sign(this.offset)

      // Fast: the direction of travel decides. Slow: the distance does.
      const commit = flicking ? withDrag && moved > FLICK_MIN_DRAG : moved >= THRESHOLD

      if (commit) this.go(this.offset < 0 ? 1 : -1, velocity)
      else this.moveTo(0, velocity)
    }

    this.el.addEventListener("touchstart", this.onStart, {passive: true})
    this.el.addEventListener("touchmove", this.onMove, {passive: false})
    this.el.addEventListener("touchend", this.onEnd, {passive: true})
    this.el.addEventListener("touchcancel", this.onEnd, {passive: true})

    this.playEnter()
    this.scheduleHint()
  },

  // A LiveView patch rewrites <main>'s attributes and drops the inline style,
  // which would flash the page to its resting place for a frame mid-slide.
  updated() {
    if (this.offset || this.entering) this.setOffset(this.offset)
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this.onStart)
    this.el.removeEventListener("touchmove", this.onMove)
    this.el.removeEventListener("touchend", this.onEnd)
    this.el.removeEventListener("touchcancel", this.onEnd)
    clearTimeout(this.hintTimer)
    clearTimeout(this.hintHoldTimer)
    if (this.anim) this.anim.stop()
    // Navigated away mid-drag: don't leave <main> (or a peek chip) stuck
    // translated for the next page.
    this.el.style.transform = ""
    this.el.style.opacity = ""
    this.resetPeeks()
  },

  withinHorizontalScroller(node) {
    for (let n = node; n && n !== this.el; n = n.parentElement) {
      if (n.scrollWidth > n.clientWidth + 1) return true
    }
    return false
  },

  setOffset(px) {
    this.offset = px
    this.el.style.transform = px ? `translateX(${px}px)` : ""
    this.el.style.opacity = this.entering ? String(1 - 0.6 * Math.min(Math.abs(px) / ENTER_FROM, 1)) : ""
    const progress = this.peeking ? Math.min(Math.abs(px) / THRESHOLD, 1) : 0
    this.setPeek(this.nextPeek, "right", px < 0 ? progress : 0)
    this.setPeek(this.prevPeek, "left", px > 0 ? progress : 0)
  },

  setPeek(el, side, progress) {
    if (!el) return
    const push = PEEK_OFFSCREEN * (1 - progress)
    const tx = side === "left" ? -push : push
    el.style.opacity = String(progress)
    el.style.transform = `translateY(-50%) translateX(${tx}px) scale(${0.85 + 0.15 * progress})`
  },

  resetPeeks() {
    for (const el of [this.prevPeek, this.nextPeek]) {
      if (!el) continue
      el.style.opacity = ""
      el.style.transform = ""
    }
  },

  // Spring <main> to `target`, starting from where it is now with the finger's
  // release velocity. Critically damped unless told otherwise.
  moveTo(target, velocity = 0, {response = 0.3, damping = 1, onDone} = {}) {
    if (this.anim) this.anim.stop()
    this.anim = spring({
      from: this.offset,
      to: target,
      velocity,
      response,
      damping,
      onUpdate: (v) => this.setOffset(v),
      onDone: () => {
        this.anim = null
        if (onDone) onDone()
      },
    })
  },

  go(direction, velocity) {
    const items = Array.from(document.querySelectorAll('#child-switcher [role="menuitem"]'))
    const index = items.findIndex((a) => a.getAttribute("aria-current") === "page")
    if (items.length < 2 || index === -1) {
      this.moveTo(0, velocity)
      return
    }
    const target = items[(index + direction + items.length) % items.length]

    this.markHintSeen()
    tick(8)

    // Keep sliding the way the user was already dragging (direction -1 is a
    // swipe right: the page moves right), at the speed they let go, and tell
    // the next page to come in from the opposite side. Navigation starts now,
    // not after the slide: the slide is just there to cover the round trip.
    const sign = direction === 1 ? -1 : 1
    try {
      sessionStorage.setItem(ENTER_KEY, JSON.stringify({sign, at: Date.now()}))
    } catch {
      // No storage: the next page just appears without the slide-in.
    }
    this.moveTo(sign * SLIDE_OUT, velocity, {response: 0.25})
    target.click()
  },

  // The page that arrives after a swipe slides in from the side opposite to the
  // one the previous page left by.
  playEnter() {
    let pending = null
    try {
      pending = JSON.parse(sessionStorage.getItem(ENTER_KEY))
      sessionStorage.removeItem(ENTER_KEY)
    } catch {
      return
    }
    if (!pending || Date.now() - pending.at > ENTER_TTL) return

    // Slide in from the far side and fade up with it. The chips stay out of it:
    // nobody is dragging.
    this.peeking = false
    this.entering = true
    this.setOffset(-pending.sign * ENTER_FROM)
    this.moveTo(0, 0, {
      response: 0.35,
      onDone: () => {
        this.peeking = true
        this.entering = false
        this.setOffset(0)
      },
    })
  },

  // A brief, unprompted preview of the gesture — plays once per device so
  // the feature is discoverable without a tutorial.
  scheduleHint() {
    if (!this.prevPeek && !this.nextPeek) return
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    if (this.hintSeen() || this.anim || this.offset !== 0) return

    this.hintTimer = setTimeout(() => this.playHint(), HINT_DELAY)
  },

  playHint() {
    if (this.startX !== null || document.visibilityState !== "visible") return
    this.markHintSeen()

    // Preview a leftward swipe -> next child, then ease back.
    this.moveTo(-Math.round(THRESHOLD * 0.65), 0, {response: 0.45})
    this.hintHoldTimer = setTimeout(() => this.moveTo(0, 0, {response: 0.4}), HINT_HOLD)
  },

  hintSeen() {
    try {
      return localStorage.getItem(HINT_KEY) === "1"
    } catch {
      return false
    }
  },

  markHintSeen() {
    try {
      localStorage.setItem(HINT_KEY, "1")
    } catch {
      // Storage unavailable (private mode, etc.) — the hint may just replay.
    }
  },
}

export default ChildSwipe
