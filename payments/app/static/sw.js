/* Service worker: caches static assets and a small whitelist of "safe"
 * pages (dashboard shell, checklist) for offline viewing.
 *
 * Deliberately NEVER caches /finance/, /merchant/, /fuel/ or any other
 * banking-adjacent route — per spec, banking data must never be cached or
 * synced while offline. Those requests always go straight to the network
 * and are simply unavailable offline (which is the safe behaviour).
 */
const CACHE_NAME = "platform-shell-v1";
const STATIC_ASSETS = [
  "/static/manifest.json",
  "/static/icons/icon-192.png",
  "/static/icons/icon-512.png",
];

// Prefixes safe to serve from cache when offline. Keep this narrow —
// anything not listed here falls through to network-only.
const SAFE_PREFIXES = ["/", "/checklist", "/notifications", "/dashboard"];
const NEVER_CACHE_PREFIXES = ["/finance", "/merchant", "/fuel", "/backups", "/export"];

function isSafePath(pathname) {
  if (NEVER_CACHE_PREFIXES.some((p) => pathname.startsWith(p))) return false;
  return SAFE_PREFIXES.some((p) => pathname === p || pathname.startsWith(p + "/"));
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS)).catch(() => {})
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

self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== self.location.origin) return;

  // Static assets: cache-first
  if (url.pathname.startsWith("/static/")) {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request).then((resp) => {
        const clone = resp.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
        return resp;
      }))
    );
    return;
  }

  // Safe pages only: network-first, falling back to cache when offline
  if (isSafePath(url.pathname)) {
    event.respondWith(
      fetch(event.request)
        .then((resp) => {
          const clone = resp.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
          return resp;
        })
        .catch(() => caches.match(event.request))
    );
  }
  // Everything else (including all finance/merchant/fuel routes): network-only, no caching.
});
