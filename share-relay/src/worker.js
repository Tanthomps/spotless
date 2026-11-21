// Spotless share relay: one Durable Object per channel (a Jam or a collaborative playlist).
//
// The relay only stores and forwards sealed boxes; it can't read them. A channel id is 32 hex;
// its key (32 bytes, AES-256-GCM) lives only in the invite link's #fragment, which browsers never
// send. Access: `token` = hex(SHA-256(key ‖ "relay")); the first connection stores its hash and
// every later one must match.
//
//   GET  /c/<id>/ws?token=…     WebSocket. On open: the backlog from the latest snapshot on, as
//                               {type:"msg", id, from, box}. Send {from, box, snap?}; it's stored
//                               and passed to every other socket.
//   GET  /c/<id>?token=…&after= HTTP read of the same log (fallback).
//   GET  /j  /p                 The web pages for a Jam link and a playlist link (share-relay/src/pages.js).
import { jamPage, playlistPage } from './pages.js';

const ID_RE = /^[0-9a-f]{32}$/;
const MAX_BOX = 256 * 1024;
const KEEP = 2000; // messages kept past the latest snapshot
const TTL_MS = 90 * 24 * 3600 * 1000; // an untouched channel is dropped after 90 days

const cors = {
	'Access-Control-Allow-Origin': '*',
	'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
	'Access-Control-Allow-Headers': 'Content-Type, Authorization'
};
const json = (v, status = 200) =>
	new Response(JSON.stringify(v), { status, headers: { 'Content-Type': 'application/json', ...cors } });

export default {
	async fetch(req, env) {
		const url = new URL(req.url);
		if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors });
		if (url.pathname === '/j' || url.pathname === '/j/') return html(jamPage);
		if (url.pathname === '/p' || url.pathname === '/p/') return html(playlistPage);
		if (url.pathname === '/') return new Response('Spotless share relay', { headers: cors });
		const m = url.pathname.match(/^\/c\/([0-9a-f]{32})(\/ws)?$/);
		if (!m || !ID_RE.test(m[1])) return json({ error: 'not_found' }, 404);
		const stub = env.CHANNEL.get(env.CHANNEL.idFromName(m[1]));
		return stub.fetch(req);
	}
};

function html(body) {
	return new Response(body, {
		headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' }
	});
}

async function sha256hex(s) {
	const d = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(s));
	return [...new Uint8Array(d)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export class Channel {
	constructor(state) {
		this.state = state;
		this.sql = state.storage.sql;
		this.sql.exec(`CREATE TABLE IF NOT EXISTS msg (id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT, box TEXT, snap INTEGER, t INTEGER)`);
		this.sql.exec(`CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT)`);
	}

	meta(k) {
		const r = this.sql.exec('SELECT v FROM meta WHERE k = ?', k).toArray();
		return r.length ? r[0].v : null;
	}
	setMeta(k, v) {
		this.sql.exec('INSERT INTO meta (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, v);
	}

	/** The first caller claims the channel with its token; later callers must present the same one. */
	async authorized(token) {
		if (!/^[0-9a-f]{64}$/.test(token || '')) return false;
		const h = await sha256hex(token);
		const have = this.meta('token');
		if (!have) {
			this.setMeta('token', h);
			return true;
		}
		return have === h;
	}

	/** Everything from the latest snapshot on (a new member's starting point), capped. */
	backlog(after = 0) {
		const snap = this.sql.exec('SELECT MAX(id) AS id FROM msg WHERE snap = 1').toArray()[0]?.id ?? 0;
		const from = Math.max(after, snap ? snap - 1 : 0);
		return this.sql.exec('SELECT id, sender, box FROM msg WHERE id > ? ORDER BY id LIMIT 1000', from).toArray();
	}

	append(sender, box, snap) {
		const now = Date.now();
		this.sql.exec('INSERT INTO msg (sender, box, snap, t) VALUES (?, ?, ?, ?)', sender, box, snap ? 1 : 0, now);
		const id = this.sql.exec('SELECT last_insert_rowid() AS id').toArray()[0].id;
		// Trim: nothing before the latest snapshot is ever read again, and past that keep KEEP.
		const s = this.sql.exec('SELECT MAX(id) AS id FROM msg WHERE snap = 1').toArray()[0]?.id ?? 0;
		this.sql.exec('DELETE FROM msg WHERE id < ? OR id <= ?', s, id - KEEP);
		this.state.storage.setAlarm(now + TTL_MS);
		return id;
	}

	async alarm() {
		await this.state.storage.deleteAll();
	}

	async fetch(req) {
		const url = new URL(req.url);
		const token = url.searchParams.get('token') || (req.headers.get('Authorization') || '').replace(/^Bearer /, '');
		if (!(await this.authorized(token))) return json({ error: 'unauthorized' }, 401);

		if (url.pathname.endsWith('/ws')) {
			if (req.headers.get('Upgrade') !== 'websocket') return json({ error: 'expected_websocket' }, 426);
			const pair = new WebSocketPair();
			this.state.acceptWebSocket(pair[1]);
			const after = Number(url.searchParams.get('after') || 0) || 0;
			for (const r of this.backlog(after)) pair[1].send(JSON.stringify({ type: 'msg', id: r.id, from: r.sender, box: r.box }));
			pair[1].send(JSON.stringify({ type: 'ready', peers: this.state.getWebSockets().length }));
			return new Response(null, { status: 101, webSocket: pair[0] });
		}
		if (req.method === 'GET') {
			const after = Number(url.searchParams.get('after') || 0) || 0;
			return json({ items: this.backlog(after).map((r) => ({ id: r.id, from: r.sender, box: r.box })) });
		}
		if (req.method === 'POST') {
			const b = await req.json().catch(() => null);
			const r = this.accept(b);
			return r.error ? json(r, 400) : json(r);
		}
		return json({ error: 'method' }, 405);
	}

	accept(b) {
		const from = typeof b?.from === 'string' ? b.from : '';
		const box = typeof b?.box === 'string' ? b.box : '';
		if (!/^[a-z0-9-]{8,64}$/.test(from) || !box || box.length > MAX_BOX || !/^[A-Za-z0-9+/=_-]+$/.test(box)) return { error: 'bad_request' };
		const id = this.append(from, box, !!b.snap);
		const out = JSON.stringify({ type: 'msg', id, from, box });
		for (const ws of this.state.getWebSockets()) {
			try {
				ws.send(out);
			} catch {
				/* closed: the runtime drops it */
			}
		}
		return { id };
	}

	webSocketMessage(ws, data) {
		let b = null;
		try {
			b = JSON.parse(typeof data === 'string' ? data : new TextDecoder().decode(data));
		} catch {
			return;
		}
		if (b?.type === 'ping') return ws.send(JSON.stringify({ type: 'pong' }));
		const r = this.accept(b);
		if (r.error) ws.send(JSON.stringify({ type: 'error', error: r.error }));
	}

	webSocketClose(ws, code) {
		try {
			ws.close(code, 'bye');
		} catch {
			/* already closed */
		}
	}
}
