// Shared Web Push plumbing.
//
// Used by both the Preferences opt-in control (`hooks/push_notifications.js`)
// and the one-time home-screen nudge (`hooks/push_prompt.js`) so the
// permission / subscribe / persist dance is written once.

export function pushSupported() {
  return (
    "serviceWorker" in navigator &&
    "PushManager" in window &&
    "Notification" in window
  )
}

export function csrfToken() {
  const el = document.querySelector("meta[name='csrf-token']")
  return el ? el.getAttribute("content") : ""
}

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/")
  const raw = atob(base64)
  const output = new Uint8Array(raw.length)
  for (let i = 0; i < raw.length; i++) output[i] = raw.charCodeAt(i)
  return output
}

// The push subscription for this device, or null if there isn't one (or the
// service worker isn't ready yet).
export async function currentPushSubscription() {
  try {
    const reg = await navigator.serviceWorker.ready
    return await reg.pushManager.getSubscription()
  } catch (_e) {
    return null
  }
}

// Ask for notification permission (MUST be called from a user gesture),
// subscribe through the service worker, and POST the subscription to the
// plain controller. Returns the resulting `Notification.permission` string;
// only "granted" means a subscription was created and saved. Throws if the
// subscribe or the network write fails.
export async function requestPushSubscription(vapidKey) {
  const permission = await Notification.requestPermission()
  if (permission !== "granted") return permission

  const reg = await navigator.serviceWorker.ready
  const subscription =
    (await reg.pushManager.getSubscription()) ||
    (await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(vapidKey),
    }))

  const res = await fetch("/push/subscriptions", {
    method: "POST",
    headers: {"content-type": "application/json", "x-csrf-token": csrfToken()},
    body: JSON.stringify(subscription.toJSON()),
  })
  if (!res.ok) throw new Error(`subscribe failed: ${res.status}`)
  return permission
}
