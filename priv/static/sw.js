// Minimal, conservative service worker: caches the app shell so the PWA opens
// offline, but never touches the LiveView websocket/longpoll or any non-GET
// request, and always prefers the network for navigations.
//
// Digested CSS/JS (`app-<hash>.css`) are cached on first successful fetch —
// do not precache `/assets/css/app.css` / `/assets/js/app.js`; those paths
// 404 in production after `mix phx.digest`.
//
// Only static, public files under `/assets/` and `/images/` are cached. Every
// other same-origin GET goes straight to the network: that keeps signed-in
// content (baby photos, `/api/v1` JSON) out of Cache Storage, where it would
// outlive the session and be served without an auth check.
//
// `/` is deliberately not precached: for a signed-out visitor it redirects to
// the login page, whose CSRF token is bound to a session that will be gone by
// the time the cached copy is served. A static offline page is the fallback.
const CACHE = "trygg-shell-v8"
const OFFLINE = "/offline.html"
// `offline.js` powers the offline quick-logger inside offline.html. Literal,
// undigested path (see the note in offline.html) so it's stable to precache.
const SHELL = [OFFLINE, "/manifest.webmanifest", "/assets/js/offline.js"]
const CACHEABLE_PREFIXES = ["/assets/", "/images/"]

// On a developer's machine `/assets/css/app.css` and `/assets/js/app.js` keep the
// same URL while they're rebuilt on every save (nothing is digested), so
// cache-first would serve a stale build indefinitely. Never cache there.
const HOST = self.location.hostname
const DEV = HOST === "localhost" || HOST === "127.0.0.1" || HOST === "[::1]" || HOST.endsWith(".localhost")

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

  // Anything that isn't a public static file (photos, the reports PDF, API
  // JSON, …) is never cached or replayed; the browser handles it as usual.
  if (DEV || !CACHEABLE_PREFIXES.some((prefix) => url.pathname.startsWith(prefix))) return

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
    // Android masks the badge to a single-colour silhouette, so a full-colour
    // icon would render as a blob.
    badge: "/images/badge-96.png",
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
