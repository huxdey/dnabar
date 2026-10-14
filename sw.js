// DNBAR service worker: telas funcionam mesmo com a internet oscilando.
// Páginas: rede primeiro (sempre a versão nova). Imagens: cache primeiro.
// Nunca guarda nada do Supabase (dados sempre ao vivo).
const CACHE = "dnbar-v1";
self.addEventListener("install", e => { self.skipWaiting(); e.waitUntil(caches.open(CACHE).then(c => c.addAll(["./", "index.html", "manifest.webmanifest", "icons/icon-192.png"]))); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET") return;
  if (url.origin !== location.origin && !url.hostname.endsWith("jsdelivr.net") && !url.hostname.endsWith("gstatic.com") && !url.hostname.endsWith("googleapis.com")) return;
  if (url.hostname.endsWith("supabase.co")) return;
  const isImg = /\.(png|jpg|jpeg|webp|svg|woff2?)$/i.test(url.pathname) || url.hostname.endsWith("jsdelivr.net") || url.hostname.endsWith("gstatic.com");
  if (isImg) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put(req, cp)); return res; })));
  } else {
    e.respondWith(fetch(req).then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put(req, cp)); return res; }).catch(() => caches.match(req).then(hit => hit || caches.match("index.html"))));
  }
});
