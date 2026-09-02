// Ticks a running-timer label once a second, purely client-side, from a
// `data-since` unix-seconds start time. The server only pushes state changes
// (start/stop), which reset the hook via `updated()`.
function fmt(totalSeconds) {
  const s = Math.max(0, Math.floor(totalSeconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const sec = s % 60
  if (h > 0) return `${h}h ${m}m`
  if (m > 0) return `${m}m ${sec}s`
  return `${sec}s`
}

const Timer = {
  mounted() {
    this.render()
    this.interval = setInterval(() => this.render(), 1000)
  },
  updated() {
    this.render()
  },
  destroyed() {
    clearInterval(this.interval)
  },
  render() {
    const since = parseInt(this.el.dataset.since, 10)
    if (Number.isNaN(since)) return
    this.el.textContent = fmt(Date.now() / 1000 - since)
  },
}

export default Timer
