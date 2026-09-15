// PPEPlan Service Worker
// Cacheia o app shell (HTML, manifest, ícones) para funcionar offline.
// Não cacheia chamadas à API do Google — essas precisam sempre de rede.

const CACHE_NAME = "ppeplan-v22-row-height-fix";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./favicon.png",
  "./Logotipo%20Horizontal.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => {
      return Promise.all(APP_SHELL.map((url) =>
        cache.add(url).catch((err) => console.warn("SW cache miss:", url, err))
      ));
    })
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  const url = new URL(req.url);

  // Chamadas Google (auth + Drive API) sempre online, sem cache
  if (url.hostname.includes("googleapis.com") || url.hostname.includes("accounts.google.com") || url.hostname.includes("google.com")) {
    return;
  }

  // App shell e recursos locais: cache-first, fallback rede
  event.respondWith(
    caches.match(req).then((cached) => {
      if (cached) return cached;
      return fetch(req).then((response) => {
        if (response && response.status === 200 && url.origin === self.location.origin) {
          const clone = response.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(req, clone));
        }
        return response;
      }).catch(() => {
        if (req.mode === "navigate") return caches.match("./index.html");
        return new Response("", { status: 504 });
      });
    })
  );
});
