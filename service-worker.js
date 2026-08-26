const CACHE_NAME = 'linecrew-pro-shell-v33';
const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.webmanifest',
  '/icons/linecrew-pro-180.png',
  '/icons/linecrew-pro-192.png',
  '/icons/linecrew-pro-512.png',
  '/expanded-jsa.js?v=20260825a',
  '/expanded-jsa-core.js?v=20260820',
  '/jsa-signatures.js?v=20260820j',
  '/jsa-signature-layout-fix.js?v=20260820a',
  '/offline-jsa.js'
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

async function addOfflineJsaLoader(response) {
  if (!response || !response.ok) return response;
  const text = await response.text();
  const loader = "\n;(()=>{if(!document.querySelector('script[data-lc-offline-jsa]')){const s=document.createElement('script');s.src='/offline-jsa.js';s.defer=false;s.dataset.lcOfflineJsa='1';document.head.appendChild(s);}})();\n";
  return new Response(text + loader, {
    status: response.status,
    statusText: response.statusText,
    headers: response.headers
  });
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
      }
      return url.pathname === '/expanded-jsa.js' ? addOfflineJsaLoader(response) : response;
    } catch (_) {
      const cached = await caches.match(request);
      if (cached) return url.pathname === '/expanded-jsa.js' ? addOfflineJsaLoader(cached) : cached;
      if (request.mode === 'navigate') return caches.match('/');
      return Response.error();
    }
  })());
});

self.addEventListener('push', (event) => {
  let payload = {};
  try {
    payload = event.data ? event.data.json() : {};
  } catch (_) {
    payload = { body: event.data ? event.data.text() : '' };
  }
  const title = payload.title || 'LineCrew Pro';
  const options = {
    body: payload.body || 'You have a new LineCrew Pro notification.',
    icon: '/icons/linecrew-pro-192.png',
    badge: '/icons/linecrew-pro-192.png',
    tag: payload.tag || undefined,
    renotify: Boolean(payload.renotify),
    data: {
      url: payload.url || '/',
      ...(payload.data || {})
    }
  };
  event.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const targetUrl = new URL(event.notification.data?.url || '/', self.location.origin).href;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if ('focus' in client) {
        if ('navigate' in client && client.url !== targetUrl) {
          try { await client.navigate(targetUrl); } catch (_) {}
        }
        await client.focus();
        return;
      }
    }
    if (self.clients.openWindow) await self.clients.openWindow(targetUrl);
  })());
});
