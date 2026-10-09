// Pulses the elements a LiveView names in a "remote-flash" event: something
// changed because another caregiver or device wrote it, and the screen should
// make that obvious. See `TryggWeb.RemoteUpdate` and `.remote-flash` in app.css.
//
// The server sends CSS selectors. LiveView dispatches the event after it has
// patched the DOM, so freshly inserted rows are already there to pulse.
// Selectors matching nothing are skipped.

const FALLBACK_MS = 2000
let waiting = new Set()

function pulse(el) {
  // Restart if it's already pulsing, e.g. two quick updates to the same card.
  el.classList.remove("remote-flash")
  void el.offsetWidth
  el.classList.add("remote-flash")

  const done = () => {
    el.classList.remove("remote-flash")
    el.removeEventListener("animationend", onEnd)
    clearTimeout(timer)
  }
  const onEnd = e => {
    if (e.animationName.startsWith("remote-flash")) done()
  }
  const timer = setTimeout(done, FALLBACK_MS)
  el.addEventListener("animationend", onEnd)
}

function run(selectors) {
  selectors.forEach(selector => document.querySelectorAll(selector).forEach(pulse))
}

window.addEventListener("phx:remote-flash", ({detail}) => {
  // An update that lands while the tab is in the background would play to
  // nobody: hold it until the caregiver is back looking at the screen.
  if (document.hidden) {
    detail.targets.forEach(t => waiting.add(t))
  } else {
    run(detail.targets)
  }
})

document.addEventListener("visibilitychange", () => {
  if (document.hidden || waiting.size === 0) return
  const selectors = [...waiting]
  waiting = new Set()
  run(selectors)
})
