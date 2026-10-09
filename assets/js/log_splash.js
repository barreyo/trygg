// A full-screen celebration for each thing a caregiver logs on Home, which
// doubles as a guard against logging it twice.
//
// The server pushes "log-splash" once a log has been saved (see `splash/2` in
// `TryggWeb.DashboardLive`). One-tap actions (a diaper button, Start sleep)
// mark themselves `data-splash-lock`: on tap, before the server has replied,
// an invisible layer covers the screen so a second tap of the same spot lands
// on the layer instead of logging again. The splash then plays on that layer.
// If the save fails the layer lifts after LOCK_MS and the error flash shows.
//
// Scenes are markup (emoji + CSS) built here; their motion lives in the
// `.log-splash` rules in app.css.

const PLAY_MS = 1600
const PLAY_MS_REDUCED = 1000
const LEAVE_MS = 260
const LOCK_MS = 1500

const SCENES = {
  diaper_pee: {caption: "Splish!", hero: "💧", rain: ["💧", 16]},
  diaper_poo: {caption: "Poo-gress!", hero: "💩", burst: ["✨", 12]},
  diaper_mixed: {caption: "Double whammy!", hero: "💩", rain: ["💧", 10], burst: ["✨", 8]},
  bottle: {caption: "Yum!", hero: "🍼", milk: true, rise: ["🫧", 12]},
  sleep_start: {caption: "Sweet dreams", hero: "🌙", twinkle: ["⭐", 14], rise: ["💤", 5]},
  sleep_stop: {caption: "Good morning!", hero: "☀️", rays: true, drift: ["☁️", 3]},
}

const rand = (min, max) => min + Math.random() * (max - min)
const reducedMotion = () => window.matchMedia("(prefers-reduced-motion: reduce)").matches

let layer = null
let playTimer = null
let leaveTimer = null
let lockTimer = null

function bits(emoji, count, style) {
  return Array.from({length: count}, (_, i) =>
    `<span class="splash-bit splash-${style}" aria-hidden="true" style="${style === "burst"
      ? `--a:${Math.round((360 / count) * i + rand(-12, 12))}deg;--dist:${Math.round(rand(110, 190))}px;`
      : `--x:${Math.round(rand(4, 96))}%;--y:${Math.round(rand(8, 88))}%;`
    }--s:${rand(0.8, 1.8).toFixed(2)};--d:${Math.round(rand(0, 700))}ms">${emoji}</span>`
  ).join("")
}

function scene(spec) {
  return [
    spec.milk && `<div class="splash-milk"></div>`,
    spec.rays && `<div class="splash-rays"></div>`,
    spec.rain && bits(spec.rain[0], spec.rain[1], "rain"),
    spec.rise && bits(spec.rise[0], spec.rise[1], "rise"),
    spec.twinkle && bits(spec.twinkle[0], spec.twinkle[1], "twinkle"),
    spec.drift && bits(spec.drift[0], spec.drift[1], "drift"),
    `<div class="splash-hero" aria-hidden="true">${spec.hero}</div>`,
    spec.burst && bits(spec.burst[0], spec.burst[1], "burst"),
    `<div class="splash-caption">${spec.caption}</div>`,
  ].filter(Boolean).join("")
}

function clearTimers() {
  clearTimeout(playTimer)
  clearTimeout(leaveTimer)
  clearTimeout(lockTimer)
}

function dismiss() {
  clearTimers()
  if (layer) layer.remove()
  layer = null
}

function ensureLayer() {
  if (layer && layer.isConnected) return layer
  layer = document.createElement("div")
  layer.id = "log-splash"
  layer.className = "log-splash"
  layer.setAttribute("aria-hidden", "true")
  document.body.append(layer)
  return layer
}

// Cover the screen right now, invisibly. Safe to call again: it just extends.
function lock() {
  ensureLayer()
  clearTimeout(lockTimer)
  lockTimer = setTimeout(dismiss, LOCK_MS)
}

function play(kind) {
  const spec = SCENES[kind]
  if (!spec) return dismiss()

  const el = ensureLayer()
  clearTimers()
  el.dataset.kind = kind
  el.classList.remove("is-leaving")
  el.innerHTML = scene(spec)
  // Restart the entrance even when replacing a scene that was mid-flight.
  el.classList.remove("is-playing")
  void el.offsetWidth
  el.classList.add("is-playing")

  const ms = reducedMotion() ? PLAY_MS_REDUCED : PLAY_MS
  playTimer = setTimeout(() => {
    el.classList.add("is-leaving")
    leaveTimer = setTimeout(dismiss, LEAVE_MS)
  }, ms - LEAVE_MS)
}

window.addEventListener("phx:log-splash", ({detail}) => play(detail.kind))

// Capture phase, so the layer is up before the second tap of a double tap.
document.addEventListener("click", e => {
  const target = e.target.closest && e.target.closest("[data-splash-lock]")
  if (target && !target.disabled) lock()
}, true)

// A focused button would still fire again on Enter or Space.
document.addEventListener("keydown", e => {
  if (layer && (e.key === "Enter" || e.key === " ")) e.preventDefault()
}, true)
