/* Service worker: caches the app so it opens offline once installed.
 * Only registers over HTTPS or localhost. Bump CACHE when app files change. */
const CACHE = "cheatday-v11";
const ASSETS = ["./", "./index.html", "./styles.css?v=11", "./presets.js?v=11", "./foods.js?v=11", "./supabase-config.js?v=11", "./cloud.js?v=11", "./app.js?v=11", "./vendor/zxing.min.js", "./manifest.webmanifest", "./icons/icon-192.png?v=11", "./icons/icon-512.png?v=11"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== location.origin) return;   // API calls go straight to the network
  e.respondWith(caches.match(e.request).then((hit) => hit || fetch(e.request)));
});
