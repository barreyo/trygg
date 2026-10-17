// Quick-entry helpers inside the Home log sheets that never need the server:
// the bottle +/- steps and presets, the "5m ago / 15m ago" time chips and the
// note suggestions. They used to be `phx-click` events, so on a poor
// connection every tap waited on a round trip before the number or time moved.
// Now they edit the form in place; the server only hears about the finished
// entry when the form is submitted (which reads the inputs straight from the DOM).
//
// The inputs they write to are marked `data-client-owned`, so a render that
// lands from an earlier change event can't put a stale value back (see
// `onBeforeElUpdated` in app.js).
//
// Buttons opt in with data attributes:
//   data-bump="5"                         add to the amount (negative to subtract)
//   data-amount-reset                     set the amount to 0
//   data-nudge-field="at" data-nudge-by="-15"
//                                         set that time field to now + minutes
//   data-note-text="Fussy"                put that text in the note field
//
// The form carries `data-timezone` (the child's zone, which may differ from the
// device's) and `data-server-now` (epoch ms when rendered) so "now" follows the
// server's clock, which is what rejects entries from the future.

// 5.0 -> "5", 2.50 -> "2.5": same shape as the server's `trim/1`.
function formatAmount(n) {
  return String(Math.round(n * 100) / 100)
}

// `YYYY-MM-DDTHH:MM` for `date` as seen in `timeZone`, the format a
// datetime-local input takes.
function localInputValue(date, timeZone) {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
    })
      .formatToParts(date)
      .map(({type, value}) => [type, value])
  )
  return `${parts.year}-${parts.month}-${parts.day}T${parts.hour}:${parts.minute}`
}

const SheetControls = {
  mounted() {
    const serverNow = Number(this.el.dataset.serverNow)
    this.skew = Number.isFinite(serverNow) && serverNow > 0 ? serverNow - Date.now() : 0

    this.onClick = (e) => {
      const btn = e.target.closest && e.target.closest("button")
      if (!btn || !this.el.contains(btn)) return

      if (btn.dataset.bump !== undefined) this.bump(Number(btn.dataset.bump))
      else if (btn.dataset.amountReset !== undefined) this.setAmount(0)
      else if (btn.dataset.nudgeField) this.nudge(btn.dataset.nudgeField, Number(btn.dataset.nudgeBy))
      else if (btn.dataset.noteText !== undefined) this.setField("note", btn.dataset.noteText)
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },

  field(name) {
    return this.el.querySelector(`[name$="[${name}]"]`)
  },

  setField(name, value) {
    const input = this.field(name)
    if (input) input.value = value
  },

  bump(by) {
    const input = this.field("amount")
    if (!input || !Number.isFinite(by)) return
    const current = parseFloat(input.value) || 0
    this.setAmount(Math.max(current + by, 0))
  },

  setAmount(n) {
    this.setField("amount", formatAmount(n))
  },

  nudge(name, minutes) {
    if (!Number.isFinite(minutes)) return
    const at = new Date(Date.now() + this.skew + minutes * 60000)
    const zone = this.el.dataset.timezone || undefined
    let value
    try {
      value = localInputValue(at, zone)
    } catch (_e) {
      // An unknown zone name: fall back to the device's own.
      value = localInputValue(at, undefined)
    }
    this.setField(name, value)
  },
}

export default SheetControls
