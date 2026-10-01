/* Cross-origin isolation and chunked-file server for static hosting.
 *
 * In a page (<script src="coi-serviceworker.js">): registers itself and reloads
 * once, so the page is served with COOP/COEP headers (SharedArrayBuffer).
 *
 * As a service worker: adds COOP/COEP headers to every response, and answers
 * requests for the large files listed in the installed manifest (see
 * package-site.py) by streaming their chunks out of Cache Storage.
 * index.html writes the chunks and the manifest into the cache "idea-<version>".
 */
if (typeof window === 'undefined') {
  const PREFIX = 'idea-';
  const SCOPE = self.registration.scope;
  const KEY = new URL('__manifest__', SCOPE).href;
  let current = null;

  self.addEventListener('install', () => self.skipWaiting());
  self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
  self.addEventListener('message', e => { if (e.data === 'refresh') current = null; });
  self.addEventListener('fetch', e => {
    const r = e.request;
    if (r.method !== 'GET' || (r.cache === 'only-if-cached' && r.mode !== 'same-origin')) return;
    e.respondWith(handle(r));
  });

  // The newest completely installed version, or null.
  async function find() {
    let best = null;
    for (const name of await caches.keys()) {
      if (!name.startsWith(PREFIX)) continue;
      const hit = await (await caches.open(name)).match(KEY);
      if (!hit) continue;
      const m = await hit.json();
      if (!best || m.built > best.m.built) best = { name, m };
    }
    if (!best) return null;
    const files = new Map(best.m.files.map(f => [new URL(f.path, SCOPE).href, f]));
    return { cache: await caches.open(best.name), files };
  }

  function installed() {
    return current || (current = find().then(i => { if (!i) current = null; return i; }));
  }

  function coi(h) {
    h.set('Cross-Origin-Embedder-Policy', 'require-corp');
    h.set('Cross-Origin-Opener-Policy', 'same-origin');
    h.set('Cross-Origin-Resource-Policy', 'cross-origin');
    return h;
  }

  function serve(inst, f) {
    let i = 0;
    const body = new ReadableStream({
      async pull(c) {
        if (i === f.chunks.length) return c.close();
        const r = await inst.cache.match(new URL(f.chunks[i++].url, SCOPE).href);
        if (!r) return c.error(new TypeError('missing chunk of ' + f.path));
        c.enqueue(new Uint8Array(await r.arrayBuffer()));
      }
    });
    return new Response(body, {
      headers: coi(new Headers({
        'Content-Type': f.type,
        'Content-Length': String(f.size),
        'Cache-Control': 'no-store'
      }))
    });
  }

  async function handle(r) {
    const u = new URL(r.url);
    if (u.origin === location.origin) {
      const inst = await installed();
      const f = inst && inst.files.get(u.origin + u.pathname);
      if (f) return serve(inst, f);
    }
    const resp = await fetch(r);
    if (resp.status === 0) return resp;
    return new Response(resp.body, {
      status: resp.status,
      statusText: resp.statusText,
      headers: coi(new Headers(resp.headers))
    });
  }
} else {
  (() => {
    const reloaded = sessionStorage.getItem('coi-reloaded');
    sessionStorage.removeItem('coi-reloaded');
    if (!('serviceWorker' in navigator) || !window.isSecureContext) return;
    navigator.serviceWorker.register(document.currentScript.src).then(() => {
      if (window.crossOriginIsolated || reloaded) return;
      navigator.serviceWorker.ready.then(() => {
        sessionStorage.setItem('coi-reloaded', '1');
        location.reload();
      });
    });
  })();
}
