const CACHE='delight-shell-v11';
const SUPABASE_SCRIPT='https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js';
const SHELL=['./index.html','./manifest.json','./icon.svg'];
self.addEventListener('install',event=>{
 event.waitUntil(caches.open(CACHE).then(async cache=>{await cache.addAll(SHELL);try{await cache.add(SUPABASE_SCRIPT)}catch(e){console.warn('Could not cache Supabase client for offline use',e)}await self.skipWaiting()}));
});
self.addEventListener('activate',event=>{
 event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('delight-shell-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim()));
});
self.addEventListener('fetch',event=>{
 const request=event.request;
 if(request.method!=='GET')return;
 const url=new URL(request.url);
 if(url.href===SUPABASE_SCRIPT){event.respondWith(caches.match(SUPABASE_SCRIPT).then(cached=>cached||fetch(request)));return}
 if(url.origin!==self.location.origin)return;
 if(request.mode==='navigate'){
  event.respondWith(fetch(request).then(response=>{
   if(response.ok){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put('./index.html',copy))}
   return response;
  }).catch(()=>caches.match('./index.html')));
  return;
 }
 event.respondWith(caches.match(request).then(cached=>cached||fetch(request).then(response=>{
  if(response.ok&&url.pathname.startsWith(self.registration.scope.replace(self.location.origin,''))){const copy=response.clone();caches.open(CACHE).then(cache=>cache.put(request,copy))}
  return response;
 })));
});