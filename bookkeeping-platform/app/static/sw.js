const CACHE_NAME = "bookkeeping-shell-v1";
const APP_SHELL = [
  "/",
  "/static/manifest.json",
  "/static/js/offline.js",
  "/static/icons/icon-192.png",
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).catch(() => {
      // Best-effort: if a shell asset 404s during install (e.g. before
      // login), don't block install of the rest.
    })
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

// Network-first for navigations (so logged-in users always see fresh data
// when online), falling back to the last cached copy of that page when
// offline. Static assets are cache-first since they don't change per
// request.
self.addEventListener("fetch", (event) => {
  const { request } = event;
  if (request.method !== "GET") return; // never intercept POSTs (sync writes)

  const url = new URL(request.url);
  const isStatic = url.pathname.startsWith("/static/");

  if (isStatic) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request))
    );
    return;
  }

  event.respondWith(
    fetch(request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        return response;
      })
      .catch(() =>
        caches.match(request).then((cached) => cached || caches.match("/"))
      )
  );
});
