// One-time home-screen nudge to turn on Web Push notifications.
//
// Mirrors `InstallPrompt`: the server renders the banner hidden and this hook
// decides whether to reveal it. It shows only when the browser can do Web
// Push, a VAPID key is configured, the notification permission is still
// undecided ("default"), this device isn't already subscribed, and the
// caregiver hasn't answered the nudge before.
//
// Once the caregiver answers — taps "Turn on" (whatever the browser dialog
// then does) or "Not now" — a localStorage flag is set and the nudge never
// returns. Re-enabling later lives on the Preferences page.
import {pushSupported, currentPushSubscription, requestPushSubscription} from "../push"

const DISMISSED_KEY = "trygg:push-prompt-dismissed"

function answered() {
  try {
    return localStorage.getItem(DISMISSED_KEY) === "1"
  } catch (_e) {
    return false
  }
}

function remember() {
  try {
    localStorage.setItem(DISMISSED_KEY, "1")
  } catch (_e) {
    // private mode; worst case the nudge reappears on the next visit
  }
}

const PushPrompt = {
  mounted() {
    this.vapidKey = this.el.dataset.vapidKey || ""
    this.enableEl = this.el.querySelector("[data-push-prompt-action='enable']")

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-push-prompt-action]")
      if (!btn) return
      e.preventDefault()
      if (btn.dataset.pushPromptAction === "enable") this.enable()
      else this.dismiss()
    })

    this.maybeShow()
  },

  async maybeShow() {
    if (
      !this.vapidKey ||
      !pushSupported() ||
      Notification.permission !== "default" ||
      answered()
    ) {
      return
    }
    if (await currentPushSubscription()) return
    this.el.hidden = false
  },

  async enable() {
    if (this.enableEl) this.enableEl.disabled = true
    try {
      await requestPushSubscription(this.vapidKey)
    } catch (e) {
      console.error(e)
    } finally {
      // Whatever the browser dialog decided, they've answered our nudge.
      remember()
      this.el.hidden = true
    }
  },

  dismiss() {
    remember()
    this.el.hidden = true
  },
}

export default PushPrompt
