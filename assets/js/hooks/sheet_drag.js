// Drag a bottom sheet down to dismiss it.
//
// Lives on the sheet's panel (see `sheet_frame/1`). The grab handle at the top
// is the drag zone; the rest of the panel keeps scrolling and focusing as
// normal. While dragging, the panel tracks the finger 1:1 and the backdrop
// fades with it. On release the end point is projected from the finger's
// velocity: a flick down throws the sheet away, a flick up (or a short, slow
// drag) springs it back. Both hand the release velocity to the spring, so there
// is no seam between dragging and animating, and grabbing the sheet again
// mid-flight picks up from where it is on screen.
//
// Closing sends the sheet's own close event (`data-close-event`), so the server
// stays the source of truth and removes the sheet; the panel just gets out of
// the way first. Phones only: from `sm` up the sheet is a centred card.

import {spring, project, rubberband, VelocityTracker} from "../spring"

const DISMISS_FRACTION = 0.5 // of the panel's height, judged on the projected end point
const FAILSAFE_MS = 1200 // if the server never closes the sheet, bring it back

const phone = () => !window.matchMedia("(min-width: 640px)").matches

const SheetDrag = {
  mounted() {
    this.backdrop = document.getElementById(`${this.el.id.replace(/-panel$/, "")}-backdrop`)
    this.offset = 0
    this.pointerId = null
    this.anim = null
    this.tracker = new VelocityTracker()

    this.onDown = (e) => {
      if (!phone() || (e.pointerType === "mouse" && e.button !== 0)) return
      const handle = e.target.closest("[data-sheet-handle]")
      if (!handle || !this.el.contains(handle)) return

      // Grabbed mid-flight: stop the spring and carry on from the live value.
      if (this.anim) {
        this.anim.stop()
        this.offset = this.anim.value
        this.anim = null
      }
      clearTimeout(this.failsafe)

      this.pointerId = e.pointerId
      this.startY = e.clientY
      this.startOffset = this.offset
      this.tracker.reset()
      this.tracker.add(e.clientY)
      handle.setPointerCapture(e.pointerId)
      e.preventDefault()
    }

    this.onMove = (e) => {
      if (e.pointerId !== this.pointerId) return
      this.tracker.add(e.clientY)
      const dy = this.startOffset + (e.clientY - this.startY)
      // Down follows the finger; up (past fully open) resists.
      this.setOffset(dy >= 0 ? dy : rubberband(dy, this.height()))
    }

    this.onUp = (e) => {
      if (e.pointerId !== this.pointerId) return
      this.pointerId = null
      const velocity = this.tracker.velocity()
      const height = this.height()
      const projected = this.offset + project(velocity)

      if (projected > height * DISMISS_FRACTION) this.dismiss(height, velocity)
      else this.settle(0, velocity)
    }

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
  },

  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onUp)
    clearTimeout(this.failsafe)
    if (this.anim) this.anim.stop()
  },

  height() {
    return this.el.getBoundingClientRect().height || window.innerHeight
  },

  setOffset(px) {
    this.offset = px
    this.el.style.transform = px ? `translateY(${px}px)` : ""
    if (this.backdrop) {
      const fade = 1 - Math.min(Math.max(px, 0) / this.height(), 1)
      this.backdrop.style.opacity = px ? String(fade) : ""
    }
  },

  // Spring to `target` carrying the release velocity. Snapping back is
  // under-damped a touch (the flick had momentum); sliding away is not.
  settle(target, velocity, damping = 0.85, onDone) {
    this.anim = spring({
      from: this.offset,
      to: target,
      velocity,
      response: 0.3,
      damping,
      onUpdate: (v) => this.setOffset(v),
      onDone: () => {
        this.anim = null
        if (onDone) onDone()
      },
    })
  },

  dismiss(height, velocity) {
    // Slide fully off the bottom, then ask the server to close.
    this.settle(height, Math.max(velocity, 0), 1, () => {
      this.pushEvent(this.el.closest("[data-close-event]").dataset.closeEvent, {})
      this.failsafe = setTimeout(() => this.settle(0, 0), FAILSAFE_MS)
    })
  },
}

export default SheetDrag
