const CACHE_NAME = 'csr-align-v5';
const urlsToCache = [
  './',
  './index.html',
  './manifest.json',
  './fonts/OCRA.ttf'
];

self.addEventListener('install', event => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return cache.addAll(urlsToCache);
    })
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(names =>
      Promise.all(names.filter(n => n !== CACHE_NAME).map(n => caches.delete(n)))
    ).then(() => self.clients.claim())
  );
});

// Network-first for the app shell only. Never intercept or cache
// non-GET requests or cross-origin traffic (Supabase reads/writes,
// Storage uploads/downloads, etc.) — this worker exists to make the
// static shell available offline, not to sit in front of live data.
// Letting the Cache API touch API calls risks a stale GET response
// masking real data, or POST/PATCH/PUT requests behaving unpredictably
// against cache.put (which several browsers reject outright for
// non-GET requests) — simplest and safest is to just never try.
self.addEventListener('fetch', event => {
  var req = event.request;
  var isSameOrigin = new URL(req.url).origin === self.location.origin;
  if (req.method !== 'GET' || !isSameOrigin) {
    event.respondWith(fetch(req));
    return;
  }
  event.respondWith(
    fetch(req).then(response => {
      var copy = response.clone();
      caches.open(CACHE_NAME).then(cache => cache.put(req, copy));
      return response;
    }).catch(() => caches.match(req).then(cached => cached || caches.match('./index.html')))
  );
});
