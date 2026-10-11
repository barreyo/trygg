// A short buzz on the moments that matter, where the platform allows it.
//
// `navigator.vibrate` exists on Android (Chrome and friends) and not in iOS
// Safari, so on an iPhone this is silent and nothing else changes. It's kept to
// commits and undos: feedback everywhere would just train people to ignore it.
// Each buzz is fired from the same event that starts the matching visual
// (the splash, the toast), so the two land together.

const supported = typeof navigator !== "undefined" && typeof navigator.vibrate === "function"

export function tick(ms = 10) {
  if (supported) navigator.vibrate(ms)
}

// The server confirmed a log: the splash plays now, so the buzz does too.
window.addEventListener("phx:log-splash", () => tick(12))

// Undo is a commit of its own.
document.addEventListener("click", (e) => {
  if (e.target.closest && e.target.closest("#undo-delete")) tick(8)
})
