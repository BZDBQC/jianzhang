const CACHE='jianzhang-shell-v3';
self.addEventListener('install',event=>{event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(['/offline.html','/icon-192.png','/icon-512.png'])).then(()=>self.skipWaiting()));});
self.addEventListener('activate',event=>{event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('jianzhang-shell-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));});
self.addEventListener('message',event=>{
  if(event.data?.type!=='CACHE_APP_SHELL'||!Array.isArray(event.data.assets))return;
  const assets=event.data.assets.filter(value=>{try{const url=new URL(value,self.location.origin);return url.origin===self.location.origin&&url.pathname.startsWith('/_next/static/');}catch{return false;}}).slice(0,100);
  event.waitUntil(caches.open(CACHE).then(cache=>Promise.allSettled(['/',...assets].map(url=>cache.add(url)))));
});
self.addEventListener('fetch',event=>{
  if(event.request.method!=='GET'||new URL(event.request.url).origin!==self.location.origin)return;
  const url=new URL(event.request.url);
  // Only the generic client-rendered app shell and versioned static assets are cached.
  // Auth endpoints and ledger API responses always go directly to the network.
  if(url.pathname.startsWith('/_next/static/'))event.respondWith((async()=>{let cache;try{cache=await caches.open(CACHE);const stored=await cache.match(event.request);if(stored)return stored;}catch{/* Network access remains usable when offline caching is unavailable. */}const response=await fetch(event.request);if(response.ok&&cache)try{await cache.put(event.request,response.clone());}catch{/* A cache quota failure must not discard a successful network response. */}return response;})());
  if(event.request.mode==='navigate'&&url.pathname==='/')event.respondWith(fetch(event.request).then(async response=>{if(response.ok&&response.headers.get('content-type')?.includes('text/html'))try{await(await caches.open(CACHE)).put('/',response.clone());}catch{/* Keep the online app usable if offline caching fails. */}return response;}).catch(async()=>await caches.match('/')??await caches.match('/offline.html')));
});
