// Swipe left/right anywhere on a child-scoped page to jump to the next/
// previous child, instead of opening the switcher dropdown every time. The
// hook lives directly on <main> (see `TryggWeb.Layouts.app/1`) and is only
// attached when there are 2+ children to switch between.
//
// A swipe drags <main> horizontally with resistance, like a carousel. Past
// the threshold, release hands off to the *existing* child-switcher link
// (`#child-switcher [role="menuitem"]`) by clicking it — so live navigation,
// aria-current, and the href itself all stay driven by the server-rendered
// menu instead of being duplicated here.
const THRESHOLD = 72 // px of horizontal drag past which release switches child
const MAX_DRAG = 120 // px <main> travels at most
const RESISTANCE = 0.5
const DIRECTION_LOCK = 10 // px of movement before we commit to swipe vs scroll

const ChildSwipe = {
  mounted() {
    this.startX = null
    this.startY = null
    this.offset = 0
    this.dragging = false // committed to a horizontal swipe
    this.locked = false // committed to letting a vertical scroll through

    this.onStart = (e) => {
      if (e.touches.length !== 1) return
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
  },

  destroyed() {
    this.el.removeEventListener("touchstart", this.onStart)
    this.el.removeEventListener("touchmove", this.onMove)
    this.el.removeEventListener("touchend", this.onEnd)
    this.el.removeEventListener("touchcancel", this.onEnd)
    // Navigated away mid-drag: don't leave <main> translated for the next page.
    this.el.style.transition = ""
    this.el.style.transform = ""
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
  },

  animateBack() {
    this.el.style.transition = "transform .2s ease"
    this.setOffset(0)
    setTimeout(() => { this.el.style.transition = "" }, 220)
  },

  go(direction) {
    const items = Array.from(document.querySelectorAll('#child-switcher [role="menuitem"]'))
    const index = items.findIndex((a) => a.getAttribute("aria-current") === "page")
    if (items.length < 2 || index === -1) {
      this.animateBack()
      return
    }
    const target = items[(index + direction + items.length) % items.length]

    this.el.style.transition = "transform .15s ease"
    this.setOffset(direction * MAX_DRAG)
    setTimeout(() => target.click(), 150)
  },
}

export default ChildSwipe
