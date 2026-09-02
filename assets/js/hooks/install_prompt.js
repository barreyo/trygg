// Nudges signed-in users to install Trygg as a home screen app.
//
// Android/Chrome fires `beforeinstallprompt`; we stash it and show an
// "Install" button that replays it. iOS has no prompt API and can't deep-link
// into a home screen web app, so we show Share → "Add to Home Screen"
// instructions instead. Hidden once installed (standalone) or dismissed.
//
// The element uses `phx-update="ignore"` since visibility is client state.
const DISMISSED_KEY = "trygg:install-dismissed"

let deferredPrompt = null

// Must be registered before the event fires, which is often before any
// LiveView hook mounts, so it lives at module scope.
window.addEventListener("beforeinstallprompt", (e) => {
  e.preventDefault()
  deferredPrompt = e
  window.dispatchEvent(new CustomEvent("trygg:installable"))
})

window.addEventListener("appinstalled", () => {
  deferredPrompt = null
  window.dispatchEvent(new CustomEvent("trygg:installed"))
})

function standalone() {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    window.matchMedia("(display-mode: fullscreen)").matches ||
    navigator.standalone === true
  )
}

function ios() {
  const ua = navigator.userAgent
  // iPadOS reports as Macintosh but is touch-capable.
  return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1)
}

function dismissed() {
  try {
    return localStorage.getItem(DISMISSED_KEY) === "1"
  } catch (_e) {
    return false
  }
}

const InstallPrompt = {
  mounted() {
    this.iosEl = this.el.querySelector("[data-install-ios]")
    this.androidEl = this.el.querySelector("[data-install-android]")

    this.onInstallable = () => this.render()
    this.onInstalled = () => this.hide()
    window.addEventListener("trygg:installable", this.onInstallable)
    window.addEventListener("trygg:installed", this.onInstalled)

    this.el.addEventListener("click", (e) => {
      const target = e.target.closest("[data-install-action]")
      if (!target) return
      const action = target.dataset.installAction

      if (action === "dismiss") {
        try {
          localStorage.setItem(DISMISSED_KEY, "1")
        } catch (_e) {
          // private mode; banner will simply reappear next visit
        }
        this.hide()
      }

      if (action === "install" && deferredPrompt) {
        deferredPrompt.prompt()
        deferredPrompt.userChoice.finally(() => {
          deferredPrompt = null
          this.hide()
        })
      }
    })

    this.render()
  },

  destroyed() {
    window.removeEventListener("trygg:installable", this.onInstallable)
    window.removeEventListener("trygg:installed", this.onInstalled)
  },

  render() {
    if (standalone() || dismissed()) return this.hide()

    if (deferredPrompt) {
      this.iosEl.hidden = true
      this.androidEl.hidden = false
      this.el.hidden = false
    } else if (ios()) {
      this.androidEl.hidden = true
      this.iosEl.hidden = false
      this.el.hidden = false
    } else {
      this.hide()
    }
  },

  hide() {
    this.el.hidden = true
  },
}

export default InstallPrompt
