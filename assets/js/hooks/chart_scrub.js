// Lets a finger (or mouse) drag across one of our custom SVG bar/heat charts
// to move the selection, instead of requiring a precise tap on each narrow
// bar. Any hit rect under the pointer that already carries a `phx-click`
// gets that event pushed to the LiveView as the pointer crosses into it.
//
// Only active while the pointer is held down and moving — a plain tap (no
// drag) is left to the element's own native phx-click binding, so we never
// double-fire the tap-to-select / tap-again-to-open behaviors those events
// carry. A hit rect already marked `data-selected="true"` is skipped so
// dragging back across the current selection doesn't re-toggle it off (or,
// for the sleep trend chart, trigger its tap-again "open this day" action).
const ChartScrub = {
  mounted() {
    this.dragging = false
    this.lastTarget = null

    this.onDown = () => {
      this.dragging = true
      this.lastTarget = null
    }
    this.onMove = (e) => {
      if (!this.dragging) return
      this.handle(e)
    }
    this.onUp = () => {
      this.dragging = false
      this.lastTarget = null
    }

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    window.addEventListener("pointerup", this.onUp)
    window.addEventListener("pointercancel", this.onUp)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    window.removeEventListener("pointerup", this.onUp)
    window.removeEventListener("pointercancel", this.onUp)
  },

  handle(e) {
    const point = document.elementFromPoint(e.clientX, e.clientY)
    const target = point && point.closest && point.closest("[phx-click]")
    if (!target || !this.el.contains(target) || target === this.lastTarget) return

    this.lastTarget = target
    if (target.dataset.selected === "true") return

    const event = target.getAttribute("phx-click")
    if (!event) return

    const payload = {}
    for (const attr of target.attributes) {
      if (attr.name.startsWith("phx-value-")) {
        payload[attr.name.slice("phx-value-".length)] = attr.value
      }
    }

    this.pushEvent(event, payload)
  },
}

export default ChartScrub
