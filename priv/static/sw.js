// Minimal, conservative service worker: caches the app shell so the PWA opens
// offline, but never touches the LiveView websocket/longpoll or any non-GET
// request, and always prefers the network for navigations.
//
// Digested CSS/JS (`app-<hash>.css`) are cached on first successful fetch —
// do not precache `/assets/css/app.css` / `/assets/js/app.js`; those paths
// 404 in production after `mix phx.digest`.
//
// `/` is deliberately not precached: for a signed-out visitor it redirects to
// the login page, whose CSRF token is bound to a session that will be gone by
// the time the cached copy is served. A static offline page is the fallback.
const CACHE = "trygg-shell-v7"
const OFFLINE = "/offline.html"
// `offline.js` powers the offline quick-logger inside offline.html. Literal,
// undigested path (see the note in offline.html) so it's stable to precache.
const SHELL = [OFFLINE, "/manifest.webmanifest", "/assets/js/offline.js"]

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()))
})

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  )
})

self.addEventListener("fetch", (event) => {
  const {request} = event
  const url = new URL(request.url)

  if (request.method !== "GET" || url.origin !== self.location.origin) return
  if (url.pathname.startsWith("/live") || url.pathname.startsWith("/phoenix")) return
  if (url.pathname === "/health") return

  if (request.mode === "navigate") {
    event.respondWith(fetch(request).catch(() => caches.match(OFFLINE)))
    return
  }

  // Reports PDF export is generated fresh per request (date window, latest
  // data) — never serve or store a cached copy, and never let a transient
  // failure response get cached and replayed on the next attempt.
  if (url.pathname.endsWith("/reports.pdf")) {
    event.respondWith(fetch(request))
    return
  }

  event.respondWith(
    caches.match(request).then((cached) => cached || fetch(request).then((res) => {
      if (res.ok) {
        const copy = res.clone()
        caches.open(CACHE).then((c) => c.put(request, copy)).catch(() => {})
      }
      return res
    }).catch(() => cached))
  )
})

// --- Web Push -------------------------------------------------------------
//
// Payloads are JSON built by `Trygg.Push` (`{title, body, url, tag}`). iOS
// Safari only delivers to an installed PWA and requires a visible
// notification for every push, so we always call showNotification.

self.addEventListener("push", (event) => {
  let payload = {}
  try {
    payload = event.data ? event.data.json() : {}
  } catch (_e) {
    payload = {body: event.data && event.data.text()}
  }

  const title = payload.title || "Trygg"
  const options = {
    body: payload.body || "",
    icon: "/images/icon-192.png",
    badge: "/images/icon-192.png",
    tag: payload.tag || "trygg",
    renotify: Boolean(payload.tag),
    data: {url: payload.url || "/"},
  }

  event.waitUntil(self.registration.showNotification(title, options))
})

self.addEventListener("notificationclick", (event) => {
  event.notification.close()
  const target = (event.notification.data && event.notification.data.url) || "/"
  const targetUrl = new URL(target, self.location.origin).href

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then((clients) => {
      for (const client of clients) {
        if (client.url === targetUrl && "focus" in client) return client.focus()
      }
      for (const client of clients) {
        if ("focus" in client && "navigate" in client) {
          return client.focus().then(() => client.navigate(targetUrl))
        }
      }
      if (self.clients.openWindow) return self.clients.openWindow(targetUrl)
    })
  )
})
