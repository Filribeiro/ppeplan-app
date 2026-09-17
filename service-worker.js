// PPEPlan Service Worker
// Rede primeiro: cada abertura usa a versão publicada mais recente;
// sem rede, usa a última cópia guardada (funciona offline).
// Não cacheia chamadas à API do Google — essas precisam sempre de rede.

// Substituído pelo Publicar-App.ps1 em cada publicação com alterações à app:
// muda os bytes deste ficheiro e a app mostra "Há uma versão nova".
const BUILD = "60D1E8F1DFB3";
const CACHE_NAME = "ppeplan-shell";
const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./favicon.png",
  "./icon-192.png",
  "./badge-96.png",
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

// Resumos da manhã/fim do dia enviados pelo PPEPlan instalado no Windows
// (PPEPlan-Push.ps1). A mensagem traz { title, body, tag }.
self.addEventListener("push", (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; }
  catch (e) { d = { body: event.data ? event.data.text() : "" }; }
  event.waitUntil(self.registration.showNotification(d.title || "PPEPlan", {
    body: d.body || "",
    tag: d.tag || "ppeplan",
    renotify: true,
    icon: "icon-192.png",
    // Ícone pequeno (barra de estado): o Android só usa a silhueta, branca em fundo transparente
    badge: "badge-96.png",
    lang: "pt-PT"
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      const open = list.find((c) => c.url.startsWith(self.registration.scope) && "focus" in c);
      return open ? open.focus() : self.clients.openWindow(self.registration.scope);
    })
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
