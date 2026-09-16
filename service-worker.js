// PPEPlan Service Worker
// Rede primeiro: cada abertura usa a versão publicada mais recente;
// sem rede, usa a última cópia guardada (funciona offline).
// Não cacheia chamadas à API do Google — essas precisam sempre de rede.

// Substituído pelo Publicar-App.ps1 em cada publicação com alterações à app:
// muda os bytes deste ficheiro e a app mostra "Há uma versão nova".
const BUILD = "A42C557B5742";
const CACHE_NAME = "ppeplan-shell";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./favicon.png",
  "./icon-192.png",
  "./icon-512.png",
  "./icon-maskable-512.png",
  "./Logotipo%20Horizontal.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) =>
      Promise.all(APP_SHELL.map((url) =>
        fetch(url, { cache: "no-cache" }).then((r) => { if (r.ok) return cache.put(url, r); })
          .catch((err) => console.warn("SW cache miss:", url, err))
      ))
    )
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
  // Google (auth + Drive API) e outros domínios: direto à rede, sem cache
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    // no-cache: revalida com o servidor (evita os 10 min de cache HTTP do GitHub Pages)
    fetch(req.url, { cache: "no-cache", credentials: "same-origin" }).then((response) => {
      if (response && response.status === 200) {
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req.url, clone));
      }
      return response;
    }).catch(() =>
      caches.match(req.url).then((cached) => {
        if (cached) return cached;
        if (req.mode === "navigate") return caches.match("./index.html");
        return new Response("", { status: 504 });
      })
    )
  );
});
