const CACHE_NAME = 'linecrew-pro-shell-v56';
const SUPABASE_RUNTIME = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.112.3/dist/umd/supabase.min.js';
const APP_SHELL = [
  '/',
  '/index.html',
  '/manifest.webmanifest',
  '/icons/linecrew-pro-180.png',
  '/icons/linecrew-pro-192.png',
  '/icons/linecrew-pro-512.png',
  '/expanded-jsa.js?v=20260901a',
  '/expanded-jsa-core.js?v=20260820',
  '/jsa-signatures.js?v=20260828a',
  '/jsa-signature-layout-fix.js?v=20260820a',
  '/offline-jsa.js?v=20260827b',
  '/jsa-review.js?v=20260826a',
  '/foreman-field-tools.js?v=20260828b',
  '/timekeeping.js?v=20260829c',
  '/timekeeping-input-v2.js?v=20260829c',
  '/timekeeping-report-v2.js?v=20260829h',
  '/timekeeping-payroll.js?v=20260828c',
  '/leadership-my-time.js?v=20260829d',
  SUPABASE_RUNTIME
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

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  const isSupabaseRuntime = request.url === SUPABASE_RUNTIME;
  if (url.origin !== self.location.origin && !isSupabaseRuntime) return;

  event.respondWith((async () => {
    try {
      const response = await fetch(request);
      if (response.ok) {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(request, copy));
      }
      return response;
    } catch (_) {
      const cached = await caches.match(request);
      if (cached) return cached;
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
