const CACHE_NAME = 'linecrew-pro-shell-v30';
const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.webmanifest',
  '/icons/linecrew-pro-180.png',
  '/icons/linecrew-pro-192.png',
  '/icons/linecrew-pro-512.png',
  '/expanded-jsa.js?v=20260825a',
  '/timekeeping-equipment-startup-hotfix.js?v=20260826a'
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

async function injectRuntimeHotfix(response) {
  const contentType = response.headers.get('content-type') || '';
  if (!response.ok || !contentType.includes('text/html')) return response;

  let html = await response.text();
  const scriptTag = '<script src="/timekeeping-equipment-startup-hotfix.js?v=20260826a"></script>';
  if (!html.includes('timekeeping-equipment-startup-hotfix.js')) {
    html = html.includes('</body>') ? html.replace('</body>', scriptTag + '\n</body>') : html + scriptTag;
  }

  const headers = new Headers(response.headers);
  headers.delete('content-length');
  return new Response(html, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  event.respondWith(
    fetch(request)
      .then(async (response) => {
        const served = request.mode === 'navigate' ? await injectRuntimeHotfix(response) : response;
        if (served.ok) {
          const copy = served.clone();
          caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
        }
        return served;
      })
      .catch(async () => {
        const cached = await caches.match(request);
        if (cached) return request.mode === 'navigate' ? injectRuntimeHotfix(cached) : cached;
        if (request.mode === 'navigate') {
          const shell = await caches.match('/');
          return shell ? injectRuntimeHotfix(shell) : Response.error();
        }
        return Response.error();
      })
  );
});
