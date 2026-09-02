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
const CACHE = "trygg-shell-v4"
const OFFLINE = "/offline.html"
const SHELL = [OFFLINE, "/manifest.webmanifest"]

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

  event.respondWith(
    caches.match(request).then((cached) => cached || fetch(request).then((res) => {
      const copy = res.clone()
      caches.open(CACHE).then((c) => c.put(request, copy)).catch(() => {})
      return res
    }).catch(() => cached))
  )
})
