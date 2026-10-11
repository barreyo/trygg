// The countdown on a night-mode step, driven by `data-ends-at` (unix
// milliseconds). The server holds when the step began, so this is the same on
// every device; it only draws it. When the time is up the label stays at 0:00,
// the element gets `data-elapsed="true"` (the page styles it) and, where the
// platform allows, the device buzzes once. A new `data-ends-at` (the next
// step) re-arms it.
function fmt(totalSeconds) {
  const s = Math.max(0, totalSeconds)
  const m = Math.floor(s / 60)
  const sec = s % 60
  return `${m}:${String(sec).padStart(2, "0")}`
}

const NightTimer = {
  mounted() {
    this.endsAt = null
    this.buzzed = false
    this.sync()
    this.interval = setInterval(() => this.render(), 250)
  },
  updated() {
    this.sync()
  },
  destroyed() {
    clearInterval(this.interval)
  },
  sync() {
    const endsAt = parseInt(this.el.dataset.endsAt, 10)
    if (endsAt !== this.endsAt) {
      this.endsAt = endsAt
      this.buzzed = false
    }
    this.render()
  },
  render() {
    if (Number.isNaN(this.endsAt)) return
    const left = Math.ceil((this.endsAt - Date.now()) / 1000)
    const label = this.el.querySelector("[data-night-time]") || this.el

    if (left > 0) {
      label.textContent = fmt(left)
      this.el.dataset.elapsed = "false"
    } else {
      label.textContent = fmt(0)
      this.el.dataset.elapsed = "true"
      if (!this.buzzed) {
        this.buzzed = true
        if (typeof navigator.vibrate === "function") navigator.vibrate([120, 80, 120])
      }
    }
  },
}

export default NightTimer
