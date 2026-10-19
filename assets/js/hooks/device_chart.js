// Scrub a crosshair across a device reading graph (see `TryggWeb.DeviceChartComponents`).
//
// The server renders the graph and embeds its points as `data-points`: a JSON array of
// [x, y, "when", "value"], x and y already in the SVG's viewBox units. Moving a finger or
// the mouse across the graph snaps a crosshair to the nearest point and writes
// "when · value" into the `[data-readout]` line under it; letting go of a mouse (or
// leaving the graph) puts the low/high summary back. Nothing here talks to the server.

const DeviceChart = {
  mounted() {
    this.svg = this.el.querySelector("svg")
    this.setup()

    this.onMove = (e) => this.show(e)
    this.onLeave = (e) => {
      // A finger lifted off keeps its reading; a mouse leaving the graph clears it.
      if (e.pointerType !== "touch") this.clear()
    }
    this.svg.addEventListener("pointerdown", this.onMove)
    this.svg.addEventListener("pointermove", this.onMove)
    this.svg.addEventListener("pointerleave", this.onLeave)
  },

  // A live update replaced the graph: read the new points and drop the stale crosshair.
  updated() {
    this.setup()
  },

  destroyed() {
    this.svg.removeEventListener("pointerdown", this.onMove)
    this.svg.removeEventListener("pointermove", this.onMove)
    this.svg.removeEventListener("pointerleave", this.onLeave)
  },

  setup() {
    this.points = JSON.parse(this.el.dataset.points || "[]")
    this.width = Number(this.el.dataset.width) || 320
    // How far from a point (in viewBox units) the pointer may be and still read it: half
    // the gap between neighbouring points, at least a fingertip.
    const xs = this.points.map((p) => p[0])
    const gaps = xs.slice(1).map((v, i) => v - xs[i]).sort((a, b) => a - b)
    this.reach = Math.max(8, (gaps[Math.floor(gaps.length / 2)] || 0) * 1.5)
    this.crosshair = this.svg.querySelector("[data-crosshair]")
    this.readout = this.el.parentElement.querySelector("[data-readout]")
  },

  show(e) {
    if (!this.points.length) return
    const rect = this.svg.getBoundingClientRect()
    const x = ((e.clientX - rect.left) / rect.width) * this.width

    let best = this.points[0]
    for (const p of this.points) {
      if (Math.abs(p[0] - x) < Math.abs(best[0] - x)) best = p
    }

    // Over the empty stretch before the first reading (or inside an outage): nothing to read.
    if (Math.abs(best[0] - x) > this.reach) return this.clear()

    const [px, py, when, value] = best
    const line = this.crosshair.querySelector("[data-crosshair-line]")
    const dot = this.crosshair.querySelector("[data-crosshair-dot]")
    line.setAttribute("x1", px)
    line.setAttribute("x2", px)
    dot.setAttribute("cx", px)
    dot.setAttribute("cy", py)
    this.crosshair.classList.remove("hidden")
    if (this.readout) this.readout.textContent = `${when} · ${value}`
  },

  clear() {
    this.crosshair.classList.add("hidden")
    if (this.readout) this.readout.textContent = this.readout.dataset.default
  },
}

export default DeviceChart
