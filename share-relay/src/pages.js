// The web side of a Spotless invite link. The key stays in the #fragment (never sent to a server);
// the page seals and opens boxes with WebCrypto AES-GCM, the same format the app uses:
// box = base64(12-byte nonce ‖ ciphertext ‖ 16-byte tag).

const shared = /* js */ `
const RELAY = location.origin;
const q = new URLSearchParams(location.hash.slice(1));
const CH = q.get('c') || '', KEY_B64 = q.get('k') || '';
const b64u = (s) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4)), (c) => c.charCodeAt(0));
const toB64 = (u) => btoa(String.fromCharCode(...u));
const fromB64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
const keyBytes = KEY_B64 ? b64u(KEY_B64) : new Uint8Array();
let KEY = null, TOKEN = '';
async function setup() {
  if (!/^[0-9a-f]{32}$/.test(CH) || keyBytes.length !== 32) throw new Error('This link is incomplete.');
  KEY = await crypto.subtle.importKey('raw', keyBytes, 'AES-GCM', false, ['encrypt', 'decrypt']);
  const t = new Uint8Array([...keyBytes, ...new TextEncoder().encode('relay')]);
  TOKEN = [...new Uint8Array(await crypto.subtle.digest('SHA-256', t))].map((b) => b.toString(16).padStart(2, '0')).join('');
}
async function seal(obj) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, KEY, new TextEncoder().encode(JSON.stringify(obj))));
  return toB64(new Uint8Array([...iv, ...ct]));
}
async function open_(box) {
  const u = fromB64(box);
  const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: u.slice(0, 12) }, KEY, u.slice(12));
  return JSON.parse(new TextDecoder().decode(pt));
}
// Drawn icons (Phosphor-style, 24 box, one stroke weight), never text glyphs.
const ICON = {
  prev: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path fill="currentColor" d="M6 4h2.4v16H6zM20 4.6v14.8a.8.8 0 0 1-1.2.7L9.4 12.7a.8.8 0 0 1 0-1.4l9.4-7.4a.8.8 0 0 1 1.2.7z"/></svg>',
  next: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><path fill="currentColor" d="M15.6 4H18v16h-2.4zM4 4.6v14.8a.8.8 0 0 0 1.2.7l9.4-7.4a.8.8 0 0 0 0-1.4L5.2 3.9a.8.8 0 0 0-1.2.7z"/></svg>',
  play: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><path fill="currentColor" d="M7.5 4.3v15.4a1 1 0 0 0 1.5.86l12.4-7.7a1 1 0 0 0 0-1.72L9 3.44a1 1 0 0 0-1.5.86z"/></svg>',
  pause: '<svg viewBox="0 0 24 24" width="22" height="22" aria-hidden="true"><rect x="5.5" y="4" width="4.5" height="16" rx="1" fill="currentColor"/><rect x="14" y="4" width="4.5" height="16" rx="1" fill="currentColor"/></svg>',
  x: '<svg viewBox="0 0 24 24" width="20" height="20" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
  plus: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><circle cx="12" cy="12" r="9.5" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M12 7.5v9M7.5 12h9" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/></svg>',
  check: '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true"><circle cx="12" cy="12" r="10.3" fill="#1ed760"/><path d="M7.5 12.3l3 3 6-6.3" fill="none" stroke="#000" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>'
};
const art = (u) => u ? '<img src="' + esc(u) + '" alt="" loading="lazy">' : '<span class="noart" aria-hidden="true"></span>';
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
`;

const style = /* css */ `
:root { --bg:#121212; --card:#1f1f1f; --card2:#2a2a2a; --text:#fff; --sub:#b3b3b3; --accent:#1ed760; }
* { box-sizing: border-box; }
html, body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.35 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
main { max-width: 560px; margin: 0 auto; padding: 20px 16px 120px; }
h1 { font-size: 24px; margin: 8px 0 4px; } .sub { color: var(--sub); font-size: 14px; }
.btn { appearance: none; border: 0; border-radius: 999px; padding: 12px 20px; font-weight: 700; font-size: 15px; cursor: pointer; }
.primary { background: var(--accent); color: #000; } .ghost { background: transparent; color: var(--text); border: 1px solid #7c7c7c; }
.row { display: flex; align-items: center; gap: 12px; padding: 8px 0; } .row img { width: 48px; height: 48px; border-radius: 4px; object-fit: cover; background: var(--card2); }
.t { font-weight: 600; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; } .a { color: var(--sub); font-size: 13px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.grow { min-width: 0; flex: 1; } .icon { width: 40px; height: 40px; border-radius: 50%; border: 0; background: transparent; color: var(--text); font-size: 18px; cursor: pointer; }
.now { background: var(--card); border-radius: 12px; padding: 16px; margin: 16px 0; } .now img { width: 100%; aspect-ratio: 1; object-fit: cover; border-radius: 8px; background: var(--card2); }
.controls { display: flex; justify-content: center; align-items: center; gap: 28px; margin-top: 12px; }
.play { width: 56px; height: 56px; border-radius: 50%; background: #fff; color: #000; border: 0; font-size: 20px; cursor: pointer; }
input { width: 100%; padding: 12px 14px; border-radius: 6px; border: 0; font-size: 16px; background: #fff; color: #000; }
.chip { display: inline-flex; align-items: center; gap: 6px; background: var(--card2); border-radius: 999px; padding: 4px 10px; font-size: 13px; margin: 2px 4px 2px 0; }
.noart { width: 48px; height: 48px; border-radius: 4px; background: var(--card2); flex: none; }
.icon, .play { display: inline-grid; place-items: center; } .icon:disabled { opacity: .5; }
.chip { max-width: 180px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.btn:disabled { opacity: .4; cursor: not-allowed; }
:focus-visible { outline: 2px solid var(--accent); outline-offset: 2px; }
::selection { background: var(--accent); color: #000; }
.err { color: #f3727f; } .hidden { display: none !important; } h2 { font-size: 18px; margin: 24px 0 6px; }
#yt { position: fixed; width: 1px; height: 1px; left: -10px; bottom: 0; opacity: 0; }
`;

export const jamPage = /* html */ `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="theme-color" content="#121212">
<title>Join the Jam</title><style>${style}</style></head><body><main>
<div id="join">
  <h1>Join the Jam</h1><p class="sub">Listen together and add songs to the queue. You can also open it in the Spotless app.</p>
  <p><input id="name" placeholder="Your name" maxlength="40" autocomplete="nickname"></p>
  <p style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn primary" id="go">Join</button><a class="btn ghost" id="app" href="#">Open in Spotless</a></p>
  <p class="err" id="err"></p>
</div>
<div id="jam" class="hidden">
  <div class="sub" id="host"></div>
  <div class="now"><img id="art" alt="" hidden><div class="row"><div class="grow"><div class="t" id="title" dir="auto">Waiting for the host…</div><div class="a" id="artists" dir="auto"></div></div></div>
    <div class="controls"><button class="icon" id="prev" aria-label="Previous"></button><button class="play" id="pp" aria-label="Play"></button><button class="icon" id="next" aria-label="Next"></button></div>
    <p style="text-align:center;margin:12px 0 0"><button class="btn ghost" id="listen">Listen on this device</button></p>
    <p class="sub" id="listenNote" style="text-align:center;margin:8px 0 0" aria-live="polite"></p>
  </div>
  <div id="members"></div>
  <h2>Add songs</h2><input id="q" placeholder="Search songs" enterkeyhint="search"><div id="results"></div>
  <h2>Up next</h2><div id="queue"></div>
</div>
<div id="yt"></div>
</main><script>${shared}
const me = { id: 'web-' + crypto.getRandomValues(new Uint32Array(2)).join('').slice(0, 14), name: '' };
let ws = null, state = null, last = 0, listen = false, player = null, ytReady = false;
const $ = (id) => document.getElementById(id);
$('app').href = 'spotless://jam?' + location.hash.slice(1);
$('prev').innerHTML = ICON.prev; $('next').innerHTML = ICON.next; $('pp').innerHTML = ICON.play;
// A link missing its key (cut off when pasted) can't work: say so before anyone types a name.
if (!/^[0-9a-f]{32}$/.test(CH) || keyBytes.length !== 32 || !q.get('p')) {
  $('err').textContent = 'This Jam link is incomplete. Ask for it again, and copy the whole thing.';
  $('go').disabled = true; $('app').classList.add('hidden');
} else if (!window.crypto?.subtle) {
  $('err').textContent = "This browser can't open Jam links. Try Safari or Chrome.";
  $('go').disabled = true;
}
$('name').value = localStorage.getItem('jam-name') || '';
$('go').onclick = async () => {
  me.name = ($('name').value.trim() || 'Guest').slice(0, 40);
  try { localStorage.setItem('jam-name', me.name); } catch {}
  try { await setup(); connect(); $('join').classList.add('hidden'); $('jam').classList.remove('hidden'); }
  catch (e) { $('err').textContent = e.message; }
};
let HOSTKEY = null, lastSeq = 0;
async function verifyHost(o) {
  try {
    if (!HOSTKEY) HOSTKEY = await crypto.subtle.importKey('raw', b64u(q.get('p') || ''), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
    const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, HOSTKEY, fromB64(o.sig), new TextEncoder().encode(o.body));
    if (!ok) return null;
    const b = JSON.parse(o.body);
    // Same Jam, and newer than the last one taken: an old message can't be replayed.
    if (b.ch !== CH || !(b.seq > lastSeq)) return null;
    lastSeq = b.seq;
    return b;
  } catch { return null; }
}
function connect() {
  ws = new WebSocket(RELAY.replace(/^http/, 'ws') + '/c/' + CH + '/ws?token=' + TOKEN + '&after=' + last);
  ws.onopen = () => send({ t: 'hello', id: me.id, name: me.name, web: true });
  ws.onmessage = async (ev) => {
    const m = JSON.parse(ev.data);
    if (m.type !== 'msg') return;
    last = Math.max(last, m.id);
    if (m.from === me.id) return;
    let o; try { o = await open_(m.box); } catch { return; }
    if (o.t === 'signed') {
      // State and "end" only count when signed by the host's key from the link.
      const s = await verifyHost(o); if (!s) return;
      if (s.t === 'state') render(s);
      else if (s.t === 'end') { state = { ...(state || {}), ended: true }; $('host').textContent = 'The Jam has ended.'; ws.close(); }
    } else if (o.t === 'results' && o.rid === rid) results(o.items || []);
  };
  ws.onclose = () => { if (!state || !state.ended) setTimeout(connect, 2000); };
}
async function send(o) { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ from: me.id, box: await seal(o) })); }
addEventListener('pagehide', () => send({ t: 'bye', id: me.id }));
function pos(s) { return ((s.posMs || 0) + (s.playing ? Date.now() - s.at : 0)) / 1000; }
function render(s) {
  state = s;
  const cur = s.items[s.index];
  $('host').textContent = (s.host?.name || 'Someone') + "'s Jam";
  if (cur?.thumbnail) { $('art').src = cur.thumbnail; $('art').hidden = false; } else $('art').hidden = true; $('title').textContent = cur?.title || 'Nothing playing'; $('artists').textContent = cur?.artists || '';
  $('pp').innerHTML = s.playing ? ICON.pause : ICON.play;
  $('pp').setAttribute('aria-label', s.playing ? 'Pause' : 'Play');
  $('members').innerHTML = (s.members || []).map((m) => '<span class="chip" dir="auto">' + esc(m.name) + '</span>').join('');
  // A long queue renders its first 100; the rest is a count (a phone can't scroll 2,000 rows well).
  const up = s.items.slice(s.index + 1), shown = up.slice(0, 100);
  $('queue').innerHTML = shown.map((it) =>
    '<div class="row">' + art(it.thumbnail) + '<div class="grow"><div class="t" dir="auto">' + esc(it.title) + '</div><div class="a" dir="auto">' + esc(it.artists) + '</div></div>' +
    '<button class="icon" aria-label="Remove ' + esc(it.title) + '" data-rm="' + esc(it.videoId) + '">' + ICON.x + '</button></div>').join('')
    + (up.length > 100 ? '<p class="sub">And ' + (up.length - 100).toLocaleString() + ' more</p>' : '')
    || '<p class="sub">Nothing queued yet. Add a song below.</p>';
  if (listen) follow();
}
$('queue').onclick = (e) => { const b = e.target.closest('[data-rm]'); if (b) { b.disabled = true; send({ t: 'remove', videoId: b.dataset.rm }); } };
$('pp').onclick = () => state && send({ t: 'cmd', op: state.playing ? 'pause' : 'play' });
$('next').onclick = () => send({ t: 'cmd', op: 'next' });
$('prev').onclick = () => send({ t: 'cmd', op: 'prev' });
let rid = '', timer = 0, waiting = 0;
// Searches run on the host's phone: if it doesn't answer in 8 s (app closed, no signal), say so.
$('q').oninput = () => { clearTimeout(timer); timer = setTimeout(() => {
  const v = $('q').value.trim(); if (!v) return results([]);
  rid = Math.random().toString(36).slice(2); const mine = rid;
  send({ t: 'search', rid, q: v }); $('results').innerHTML = '<p class="sub">Searching…</p>';
  clearTimeout(waiting);
  waiting = setTimeout(() => { if (rid === mine) $('results').innerHTML = '<p class="sub">The host didn’t answer. Their app may be closed. <button class="btn ghost" id="again">Try again</button></p>'; }, 8000);
}, 350); };
$('results').addEventListener('click', (e) => { if (e.target.id === 'again') $('q').oninput(); });
let found = [];
function results(items) {
  clearTimeout(waiting);
  found = items;
  const v = $('q').value.trim();
  $('results').innerHTML = items.map((it, i) => '<div class="row">' + art(it.thumbnail) + '<div class="grow"><div class="t">' + esc(it.title) + '</div><div class="a">' + esc(it.artists) + '</div></div><button class="icon" aria-label="Add ' + esc(it.title) + '" data-add="' + i + '">' + ICON.plus + '</button></div>').join('') || (v ? '<p class="sub">No songs found for “' + esc(v) + '”.</p>' : '');
}
$('results').onclick = (e) => {
  const b = e.target.closest('[data-add]'); if (!b || b.disabled) return;
  send({ t: 'add', song: found[+b.dataset.add] });
  b.innerHTML = ICON.check; b.disabled = true; b.setAttribute('aria-label', 'Added');
};
// Listening here: a hidden YouTube player follows the host (song, position, play/pause).
$('listen').onclick = () => {
  listen = !listen; $('listen').textContent = listen ? 'Stop listening here' : 'Listen on this device';
  if (!listen) { player && player.pauseVideo(); return; }
  if (!ytReady) { const s = document.createElement('script'); s.src = 'https://www.youtube.com/iframe_api'; document.head.appendChild(s); }
  else follow();
};
window.onYouTubeIframeAPIReady = () => {
  player = new YT.Player('yt', { height: '1', width: '1', playerVars: { playsinline: 1, controls: 0 }, events: {
    onReady: () => { ytReady = true; follow(); },
    // 101/150: the owner blocks playing it outside YouTube; 100: removed. The Jam keeps going.
    onError: (e) => { $('listenNote').textContent = (e.data === 101 || e.data === 150 || e.data === 100) ? "This song can't play in the browser. It'll pick up on the next one." : "Couldn't play this song here."; },
    onStateChange: (e) => { if (e.data === 1) $('listenNote').textContent = ''; }
  } });
};
function follow() {
  if (!player || !ytReady || !state) return;
  const cur = state.items[state.index]; if (!cur) return;
  const want = pos(state), id = player.getVideoData?.().video_id;
  if (id !== cur.videoId) player.loadVideoById(cur.videoId, want);
  else if (Math.abs(player.getCurrentTime() - want) > 3) player.seekTo(want, true);
  state.playing ? player.playVideo() : player.pauseVideo();
}
setInterval(() => { if (listen) follow(); if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'ping' })); }, 15000);
</script></body></html>`;

export const playlistPage = /* html */ `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><meta name="theme-color" content="#121212">
<title>Collaborative playlist</title><style>${style}</style></head><body><main>
<h1 id="n">Collaborative playlist</h1><p class="sub">You've been invited to add and remove songs together. Open this link on an iPhone or Mac with Spotless installed.</p>
<p><a class="btn primary" id="app" href="#">Open in Spotless</a></p>
</main><script>
const q = new URLSearchParams(location.hash.slice(1));
if (q.get('n')) document.getElementById('n').textContent = q.get('n');
document.getElementById('app').href = 'spotless://collab?' + location.hash.slice(1);
</script></body></html>`;
