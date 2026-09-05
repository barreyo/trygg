// Opt-in control for OS-level Web Push notifications on the installed PWA.
//
// Lives on the Preferences page. Notification permission MUST be requested
// from a user gesture, so the actual `Notification.requestPermission()` /
// `pushManager.subscribe()` calls hang off the button click. The resulting
// subscription is POSTed to a plain controller (`/push/subscriptions`), not a
// LiveView event, because the service-worker registration it needs isn't tied
// to the live socket.
//
// The element is `phx-update="ignore"`; all visible state is client-side.
// Expected children (toggled by `hidden`):
//   [data-push-status]        status line
//   [data-push-action=enable] "turn on" button
//   [data-push-action=disable]"turn off on this device" button
//   [data-push-unsupported]   shown when the browser can't do Web Push

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  const output = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i)
  return output
}

function csrfToken() {
  const el = document.querySelector("meta[name='csrf-token']")
  return el ? el.getAttribute("content") : ""
}

function supported() {
  return (
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  )
}

const PushNotifications = {
  mounted() {
    this.vapidKey = this.el.dataset.vapidKey || ""
    this.statusEl = this.el.querySelector("[data-push-status]")
    this.enableEl = this.el.querySelector("[data-push-action='enable']")
    this.disableEl = this.el.querySelector("[data-push-action='disable']")
    this.unsupportedEl = this.el.querySelector("[data-push-unsupported]")

    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest("[data-push-action]")
      if (!btn) return
      e.preventDefault()
      if (btn.dataset.pushAction === "enable") this.enable()
      if (btn.dataset.pushAction === "disable") this.disable()
    })

    this.refresh()
  },

  async refresh() {
    if (!supported() || !this.vapidKey) {
      this.show(this.unsupportedEl, true)
      this.show(this.enableEl, false)
      this.show(this.disableEl, false)
      this.setStatus("")
      return
    }
    this.show(this.unsupportedEl, false)

    const permission = Notification.permission
    let subscription = null
    try {
      const reg = await navigator.serviceWorker.ready
      subscription = await reg.pushManager.getSubscription()
    } catch (_e) {
      // registration not ready yet; treat as not subscribed
    }

    if (permission === "denied") {
      this.setStatus("Notifications are blocked. Turn them back on in your browser or device settings.")
      this.show(this.enableEl, false)
      this.show(this.disableEl, false)
      return
    }

    if (subscription) {
      this.setStatus("On for this device. You'll get a nudge here when something needs a look.")
      this.show(this.enableEl, false)
      this.show(this.disableEl, true)
    } else {
      this.setStatus("Off on this device. Turn them on to get reminders even when Trygg is closed.")
      this.enableEl.textContent =
        permission === "granted" ? "Turn on for this device" : "Turn on notifications"
      this.show(this.enableEl, true)
      this.show(this.disableEl, false)
    }
  },

  async enable() {
    this.busy(true)
    try {
      const permission = await Notification.requestPermission()
      if (permission !== "granted") {
        await this.refresh()
        return
      }

      const reg = await navigator.serviceWorker.ready
      const subscription =
        (await reg.pushManager.getSubscription()) ||
        (await reg.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(this.vapidKey),
        }))

      const res = await fetch("/push/subscriptions", {
        method: "POST",
        headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
        body: JSON.stringify(subscription.toJSON()),
      })
      if (!res.ok) throw new Error(`subscribe failed: ${res.status}`)
    } catch (e) {
      this.setStatus("Couldn't turn notifications on. Please try again.")
      console.error(e)
    } finally {
      this.busy(false)
      await this.refresh()
    }
  },

  async disable() {
    this.busy(true)
    try {
      const reg = await navigator.serviceWorker.ready
      const subscription = await reg.pushManager.getSubscription()
      if (subscription) {
        const {endpoint} = subscription
        await subscription.unsubscribe()
        await fetch("/push/subscriptions", {
          method: "DELETE",
          headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
          body: JSON.stringify({endpoint}),
        })
      }
    } catch (e) {
      console.error(e)
    } finally {
      this.busy(false)
      await this.refresh()
    }
  },

  setStatus(text) {
    if (this.statusEl) this.statusEl.textContent = text
  },

  show(el, visible) {
    if (el) el.hidden = !visible
  },

  busy(on) {
    for (const el of [this.enableEl, this.disableEl]) {
      if (el) el.disabled = on
    }
  },
}

export default PushNotifications
