// Small motion toolkit for gesture-driven UI: a spring that starts from where
// the thing actually is and carries the finger's velocity, plus the helpers
// that go with it (velocity tracking, momentum projection, rubber-banding).
//
// A spring is described the way designers think about it, not as
// mass/stiffness/damping:
//
//   * `damping`  1 is critically damped (smooth settle, no overshoot); below 1
//                it overshoots. Use ~0.8 only when the gesture itself carried
//                momentum (a flick), 1 for everything else.
//   * `response` roughly how long, in seconds, it takes to get there. Not a
//                duration: the settle time falls out of the parameters.
//
// Because a spring only ever chases a target, it can be grabbed and redirected
// at any instant: stop it, read `value`, and start the next one from there.

const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches

const SUBSTEP = 1 / 240 // s; keeps the integration stable on long frames
const REST_DISTANCE = 0.4 // px
const REST_SPEED = 4 // px/s

// Animate a number from `from` to `to`. `velocity` is in units/s, so a drag's
// release velocity can be handed straight in (no visible seam between dragging
// and animating). Returns a handle with `stop()`, `value` and `velocity` so an
// interruption can continue from the live, on-screen value.
export function spring({from, to, velocity = 0, response = 0.35, damping = 1, onUpdate, onDone}) {
  const handle = {
    value: from,
    velocity,
    stop() {
      cancelAnimationFrame(raf)
      stopped = true
    },
  }
  let raf = 0
  let stopped = false

  // Reduced motion keeps the result but drops the travel.
  if (reducedMotion()) {
    handle.value = to
    handle.velocity = 0
    onUpdate(to)
    if (onDone) onDone()
    return handle
  }

  const stiffness = (2 * Math.PI / response) ** 2
  const drag = (4 * Math.PI * damping) / response
  let last = null

  const frame = (now) => {
    if (stopped) return
    if (last === null) last = now
    // A backgrounded tab can hand us a huge gap; don't integrate across it.
    const dt = Math.min((now - last) / 1000, 1 / 20)
    last = now

    if (dt > 0) {
      const steps = Math.ceil(dt / SUBSTEP)
      const h = dt / steps
      for (let i = 0; i < steps; i++) {
        const accel = -stiffness * (handle.value - to) - drag * handle.velocity
        handle.velocity += accel * h
        handle.value += handle.velocity * h
      }
    }

    if (Math.abs(handle.value - to) < REST_DISTANCE && Math.abs(handle.velocity) < REST_SPEED) {
      handle.value = to
      handle.velocity = 0
      onUpdate(to)
      if (onDone) onDone()
      return
    }
    onUpdate(handle.value)
    raf = requestAnimationFrame(frame)
  }

  raf = requestAnimationFrame(frame)
  return handle
}

// Release velocity from the last ~100ms of pointer samples, in px/s. A finger
// that paused before lifting reads as 0, which is what it should.
export class VelocityTracker {
  constructor(windowMs = 100) {
    this.windowMs = windowMs
    this.samples = []
  }

  reset() {
    this.samples = []
  }

  add(position, time = performance.now()) {
    this.samples.push({position, time})
    const cutoff = time - this.windowMs
    while (this.samples.length > 2 && this.samples[0].time < cutoff) this.samples.shift()
  }

  velocity() {
    if (this.samples.length < 2) return 0
    const first = this.samples[0]
    const last = this.samples[this.samples.length - 1]
    // Stale: the finger sat still before it lifted.
    if (performance.now() - last.time > this.windowMs) return 0
    const dt = (last.time - first.time) / 1000
    return dt > 0 ? (last.position - first.position) / dt : 0
  }
}

// Where a flick at `velocity` (px/s) would come to rest, using scroll-style
// exponential deceleration. Choose the snap target nearest this point rather
// than the release point, so a flick throws the element.
export function project(velocity, decelerationRate = 0.998) {
  return ((velocity / 1000) * decelerationRate) / (1 - decelerationRate)
}

// Resistance that grows the further past a boundary you drag: it still follows
// the finger, just less and less. `dimension` is the size of the thing being
// dragged (or the viewport).
export function rubberband(overshoot, dimension, constant = 0.55) {
  const abs = Math.abs(overshoot)
  const eased = (abs * dimension * constant) / (dimension + constant * abs)
  return overshoot < 0 ? -eased : eased
}
