// Reordering in the "Customize Home" sheet.
//
// Lives on the sheet's form. Rows are `[data-reorder-row]` (their ids are
// stable), each with a `[data-drag-handle]`; the up/down buttons
// (`[data-move="up|down"]`) stay as the accessible way to do the same thing.
//
// The order is edited right here in the DOM and the server only hears about it
// when the form is submitted (the `layout[order][]` hidden inputs are read in
// DOM order), so nothing waits on the connection.
//
//  * Rows glide to their new place whenever the order changes, whatever
//    changed it (a drop, a button, or someone else rearranging Home): the hook
//    records where every row is before the change and springs each from there
//    to where it landed (FLIP).
//  * Dragging a handle lifts the row: it follows the finger 1:1, the rows it
//    passes slide out of its way, and on release it springs into its slot with
//    the finger's velocity. Then the row is moved to that slot in the DOM.
//    Because the rows are already sitting where the new order puts them, that
//    changes nothing visible.

import {spring, VelocityTracker} from "../spring"

const LayoutReorder = {
  mounted() {
    this.drag = null
    this.anims = new Map()
    this.tracker = new VelocityTracker()

    this.onDown = (e) => {
      if (e.pointerType === "mouse" && e.button !== 0) return
      const handle = e.target.closest("[data-drag-handle]")
      const row = handle && handle.closest("[data-reorder-row]")
      if (!row || this.drag) return

      const rows = this.rows()
      const rects = rows.map((r) => r.getBoundingClientRect())
      const index = rows.indexOf(row)
      const gap = rects.length > 1 ? rects[1].top - rects[0].bottom : 0

      this.stopAnims()
      this.drag = {
        row,
        rows,
        rects,
        gap,
        from: index,
        to: index,
        startY: e.clientY,
        pointerId: e.pointerId,
        offset: 0,
      }
      this.tracker.reset()
      this.tracker.add(0)

      handle.setPointerCapture(e.pointerId)
      row.style.zIndex = "1"
      row.style.position = "relative"
      row.classList.add("shadow-lg")
      for (const r of rows) if (r !== row) r.style.transition = "transform 180ms cubic-bezier(0.2, 0.8, 0.2, 1)"
      e.preventDefault()
    }

    this.onMove = (e) => {
      const d = this.drag
      if (!d || e.pointerId !== d.pointerId) return
      const first = d.rects[0].top - d.rects[d.from].top
      const last = d.rects[d.rects.length - 1].top - d.rects[d.from].top
      // The row stays inside the list.
      d.offset = Math.min(Math.max(e.clientY - d.startY, first), last)
      this.tracker.add(d.offset)
      d.row.style.transform = `translateY(${d.offset}px)`

      // Which slot is the dragged row's centre over?
      const centre = d.rects[d.from].top + d.rects[d.from].height / 2 + d.offset
      let to = d.from
      d.rects.forEach((r, i) => {
        if (Math.abs(centre - (r.top + r.height / 2)) < Math.abs(centre - (d.rects[to].top + d.rects[to].height / 2))) to = i
      })
      if (to !== d.to) {
        d.to = to
        this.shiftNeighbours()
      }
    }

    this.onUp = (e) => {
      const d = this.drag
      if (!d || e.pointerId !== d.pointerId) return
      const velocity = this.tracker.velocity()
      const target = this.slotOffset(d, d.to)

      this.anims.set(
        d.row,
        spring({
          from: d.offset,
          to: target,
          velocity,
          response: 0.3,
          damping: 0.9,
          onUpdate: (v) => (d.row.style.transform = `translateY(${v}px)`),
          onDone: () => this.drop(d),
        }),
      )
    }

    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest("[data-move]")
      if (!btn || btn.disabled || this.drag) return
      const row = btn.closest("[data-reorder-row]")
      const next = btn.dataset.move === "up" ? row.previousElementSibling : row.nextElementSibling
      if (!row || !next || !next.matches("[data-reorder-row]")) return
      this.flip(() => (btn.dataset.move === "up" ? next.before(row) : next.after(row)))
    }

    this.el.addEventListener("click", this.onClick)
    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onUp)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onUp)
    this.stopAnims()
  },

  rows() {
    return Array.from(this.el.querySelectorAll("[data-reorder-row]"))
  },

  stopAnims() {
    for (const anim of this.anims.values()) anim.stop()
    this.anims.clear()
  },

  // How far the dragged row has to travel to sit in slot `to`.
  slotOffset(d, to) {
    return d.rects[to].top - d.rects[d.from].top
  },

  // Rows between the dragged row's start and its current slot step aside by
  // exactly one row (plus gap) so the gap follows the drag.
  shiftNeighbours() {
    const d = this.drag
    const step = d.rects[d.from].height + d.gap
    d.rows.forEach((r, i) => {
      if (r === d.row) return
      let shift = 0
      if (d.from < d.to && i > d.from && i <= d.to) shift = -step
      if (d.from > d.to && i < d.from && i >= d.to) shift = step
      r.style.transform = shift ? `translateY(${shift}px)` : ""
    })
  },

  // The row is in its slot: make that the order. Everything already sits where
  // the new order puts it, so clearing the offsets after the move shows no jump.
  drop(d) {
    this.anims.delete(d.row)
    this.drag = null
    d.row.classList.remove("shadow-lg")

    if (d.to !== d.from) {
      const anchor = d.rows[d.to]
      if (d.to > d.from) anchor.after(d.row)
      else anchor.before(d.row)
    }
    this.resetRows(d.rows)
    this.syncButtons()
  },

  // The first row can't go up, the last can't go down.
  syncButtons() {
    const rows = this.rows()
    rows.forEach((row, i) => {
      const up = row.querySelector('[data-move="up"]')
      const down = row.querySelector('[data-move="down"]')
      if (up) up.disabled = i === 0
      if (down) down.disabled = i === rows.length - 1
    })
  },

  // Run `mutate` (which reorders rows) and glide every row from where it was.
  flip(mutate) {
    const before = new Map(this.rows().map((r) => [r.id, r.getBoundingClientRect().top]))
    mutate()
    this.syncButtons()
    this.glide(before)
  },

  resetRows(rows) {
    for (const r of rows) {
      r.style.transform = ""
      r.style.transition = ""
      r.style.zIndex = ""
      r.style.position = ""
    }
  },

  // FLIP: remember where every row is, ...
  beforeUpdate() {
    this.before = new Map(this.rows().map((r) => [r.id, r.getBoundingClientRect().top]))
  },

  // ... then spring each one from there to where it landed.
  updated() {
    const before = this.before
    this.before = null
    if (!before || this.drag) return
    this.glide(before)
  },

  // Spring every row from its old top (`before`, by id) to where it is now.
  glide(before) {
    // Measure against the natural layout, whatever inline styles survived.
    const rows = this.rows()
    for (const row of rows) {
      row.style.transform = ""
      row.style.transition = ""
      row.style.zIndex = ""
      row.style.position = ""
    }
    for (const row of rows) {
      const old = before.get(row.id)
      if (old === undefined) continue
      const delta = old - row.getBoundingClientRect().top
      if (Math.abs(delta) < 1) continue
      if (this.anims.has(row)) this.anims.get(row).stop()
      row.style.transform = `translateY(${delta}px)`
      this.anims.set(
        row,
        spring({
          from: delta,
          to: 0,
          response: 0.35,
          damping: 1,
          onUpdate: (v) => (row.style.transform = v ? `translateY(${v}px)` : ""),
          onDone: () => this.anims.delete(row),
        }),
      )
    }
  },
}

export default LayoutReorder
