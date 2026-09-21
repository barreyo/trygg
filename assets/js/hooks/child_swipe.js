// Swipe left/right anywhere on a child-scoped page to jump to the next/
// previous child, instead of opening the switcher dropdown every time. The
// hook lives directly on <main> (see `TryggWeb.Layouts.app/1`) and is only
// attached when there are 2+ children to switch between.
//
// A swipe drags <main> horizontally with resistance, like a carousel, while
// a small chip for the child you'd land on (`#child-swipe-peek-prev` /
// `-next`, also rendered by the layout) slides in from that edge — so
// mid-drag you already see who you're about to switch to. Past the
// threshold, release hands off to the *existing* child-switcher link
// (`#child-switcher [role="menuitem"]`) by clicking it — so live navigation,
// aria-current, and the href itself all stay driven by the server-rendered
// menu instead of being duplicated here.
//
// The first time this hook ever mounts on a device, it also plays a brief,
// unprompted preview of the gesture (a small nudge + peek) so the feature is
// discoverable without a tutorial. It never plays again after that (tracked
// in localStorage) and is skipped entirely under reduced-motion.
const THRESHOLD = 72 // px of horizontal drag past which release switches child
const MAX_DRAG = 120 // px <main> travels at most
const RESISTANCE = 0.5
const DIRECTION_LOCK = 10 // px of movement before we commit to swipe vs scroll

const PEEK_OFFSCREEN = 28 // extra px a peek chip sits beyond its resting spot while hidden

const HINT_KEY = "trygg:child-swipe-hint-seen"
const HINT_DELAY = 900 // ms after mount before the one-time hint plays
const HINT_HOLD = 650 // ms the hint's peek stays out before easing back

const ChildSwipe = {
  mounted() {
    this.startX = null
    this.startY = null
    this.offset = 0
    this.dragging = false // committed to a horizontal swipe
    this.locked = false // committed to letting a vertical scroll through

    this.prevPeek = document.getElementById("child-swipe-peek-prev")
    this.nextPeek = document.getElementById("child-swipe-peek-next")

    this.onStart = (e) => {
      if (e.touches.length !== 1) return
      clearTimeout(this.hintTimer)
      // A horizontally scrollable ancestor (charts, timelines) owns its own
      // gesture; don't steal it.
      if (this.withinHorizontalScroller(e.target)) return
      this.startX = e.touches[0].clientX
      this.startY = e.touches[0].clientY
      this.dragging = false
      this.locked = false
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
        this.el.style.transition = ""
      }
      if (!this.dragging) return

      if (e.cancelable) e.preventDefault()
      this.setOffset(Math.max(-MAX_DRAG, Math.min(MAX_DRAG, dx * RESISTANCE)))
    }

    this.onEnd = () => {
      this.startX = null
      if (!this.dragging) return
      this.dragging = false

      if (this.offset <= -THRESHOLD) this.go(1) // swiped left -> next child
      else if (this.offset >= THRESHOLD) this.go(-1) // swiped right -> previous child
      else this.animateBack()
    }

    this.el.addEventListener("touchstart", this.onStart, {passive: true})
    this.el.addEventListener("touchmove", this.onMove, {passive: false})
    this.el.addEventListener("touchend", this.onEnd, {passive: true})
    this.el.addEventListener("touchcancel", this.onEnd, {passive: true})

    this.scheduleHint()
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this.onStart)
    this.el.removeEventListener("touchmove", this.onMove)
    this.el.removeEventListener("touchend", this.onEnd)
    this.el.removeEventListener("touchcancel", this.onEnd)
    clearTimeout(this.hintTimer)
    clearTimeout(this.hintHoldTimer)
    // Navigated away mid-drag: don't leave <main> (or a peek chip) stuck
    // translated for the next page.
    this.el.style.transition = ""
    this.el.style.transform = ""
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
    const progress = Math.min(Math.abs(px) / THRESHOLD, 1)
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
      el.style.transition = ""
      el.style.opacity = ""
      el.style.transform = ""
    }
  },

  animateBack() {
    this.el.style.transition = "transform .2s ease"
    for (const el of [this.prevPeek, this.nextPeek]) {
      if (el) el.style.transition = "transform .2s ease, opacity .2s ease"
    }
    this.setOffset(0)
    setTimeout(() => {
      this.el.style.transition = ""
      for (const el of [this.prevPeek, this.nextPeek]) {
        if (el) el.style.transition = ""
      }
    }, 220)
  },

  go(direction) {
    const items = Array.from(document.querySelectorAll('#child-switcher [role="menuitem"]'))
    const index = items.findIndex((a) => a.getAttribute("aria-current") === "page")
    if (items.length < 2 || index === -1) {
      this.animateBack()
      return
    }
    const target = items[(index + direction + items.length) % items.length]

    this.markHintSeen()

    // Keep sliding the same way the user was already dragging (don't flip
    // direction), so the right peek chip finishes sliding fully into view.
    const sign = this.offset < 0 ? -1 : 1
    this.el.style.transition = "transform .15s ease"
    this.setOffset(sign * MAX_DRAG)
    setTimeout(() => target.click(), 150)
  },

  // A brief, unprompted preview of the gesture — plays once per device so
  // the feature is discoverable without a tutorial.
  scheduleHint() {
    if (!this.prevPeek && !this.nextPeek) return
    if (window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    if (this.hintSeen()) return

    this.hintTimer = setTimeout(() => this.playHint(), HINT_DELAY)
  },

  playHint() {
    if (this.startX !== null || document.visibilityState !== "visible") return
    this.markHintSeen()

    this.el.style.transition = "transform .55s cubic-bezier(.22,1,.36,1)"
    for (const el of [this.prevPeek, this.nextPeek]) {
      if (el) el.style.transition = "transform .55s cubic-bezier(.22,1,.36,1), opacity .55s ease"
    }
    this.setOffset(-Math.round(THRESHOLD * 0.65)) // preview a leftward swipe -> next child

    this.hintHoldTimer = setTimeout(() => this.animateBack(), HINT_HOLD)
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
