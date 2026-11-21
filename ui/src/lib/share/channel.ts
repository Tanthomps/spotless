// One share-relay channel (Jam or collaborative playlist), the Mac's twin of the iPhone's
// ShareChannel (ios/Encore/Encore/App/JamCollabStores.swift) and the Jam web page: a WebSocket to
// the relay, AES-256-GCM boxes (12-byte nonce ‖ ciphertext ‖ tag, base64), the key only in the link.
import type { SongItem } from '$lib/api';

export const RELAY = 'https://spotless-share.tanthompsig.workers.dev';

/** A song on the wire (camelCase, as the iPhone and the web page send it). */
export type WireSong = { videoId: string; title: string; artists: string; thumbnail?: string | null; duration?: string | null };
export const toWire = (s: SongItem): WireSong => ({
	videoId: s.video_id,
	title: s.title,
	artists: s.artists,
	thumbnail: s.thumbnail ?? null,
	duration: s.duration ?? null
});
export const fromWire = (w: WireSong): SongItem =>
	({ video_id: w.videoId, title: w.title, artists: w.artists, thumbnail: w.thumbnail ?? undefined, duration: w.duration ?? undefined }) as SongItem;

const enc = new TextEncoder();
const toB64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));
const fromB64 = (s: string) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
export const b64url = (u: Uint8Array) => toB64(u).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
export const fromB64url = (s: string) => fromB64(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4));
const hex = (u: Uint8Array) => [...u].map((b) => b.toString(16).padStart(2, '0')).join('');

/** This Mac's id on channels (stable per install). */
export function shareMe(): string {
	let v = localStorage.getItem('share.me');
	if (!v) {
		v = 'mac-' + hex(crypto.getRandomValues(new Uint8Array(8)));
		localStorage.setItem('share.me', v);
	}
	return v;
}

export function parseFragment(fragment: string): { id: string; key: Uint8Array; q: URLSearchParams } | null {
	const q = new URLSearchParams(fragment.replace(/^[#?]/, ''));
	const id = q.get('c') ?? '';
	const k = q.get('k') ?? '';
	if (!/^[0-9a-f]{32}$/.test(id) || !k) return null;
	const key = fromB64url(k);
	return key.length === 32 ? { id, key, q } : null;
}

export class Channel {
	onMessage: (m: Record<string, unknown>, from: string) => void = () => {};
	onState: (up: boolean) => void = () => {};
	onCursor: (n: number) => void = () => {};
	lastId = 0;
	failures = 0;
	up = false;
	private ws: WebSocket | null = null;
	private closed = false;
	private aes: Promise<CryptoKey>;
	private token: Promise<string>;
	private ping = 0;

	constructor(
		readonly id: string,
		readonly key: Uint8Array,
		readonly me: string
	) {
		this.aes = crypto.subtle.importKey('raw', new Uint8Array(key), 'AES-GCM', false, ['encrypt', 'decrypt']);
		this.token = crypto.subtle.digest('SHA-256', new Uint8Array([...key, ...enc.encode('relay')])).then((d) => hex(new Uint8Array(d)));
	}

	static make(me: string) {
		return new Channel(hex(crypto.getRandomValues(new Uint8Array(16))), crypto.getRandomValues(new Uint8Array(32)), me);
	}

	get fragment() {
		return `c=${this.id}&k=${b64url(this.key)}`;
	}

	async connect() {
		this.closed = false;
		const url = `${RELAY.replace(/^http/, 'ws')}/c/${this.id}/ws?token=${await this.token}&after=${this.lastId}`;
		const ws = new WebSocket(url);
		this.ws = ws;
		ws.onmessage = async (ev) => {
			if (!this.up) {
				this.up = true;
				this.failures = 0;
				this.onState(true);
			}
			const o = JSON.parse(String(ev.data));
			if (o.type !== 'msg') return;
			if (o.id > this.lastId) {
				this.lastId = o.id;
				this.onCursor(o.id);
			}
			if (o.from === this.me) return;
			try {
				const u = fromB64(o.box);
				const pt = await crypto.subtle.decrypt({ name: 'AES-GCM', iv: u.slice(0, 12) }, await this.aes, u.slice(12));
				this.onMessage(JSON.parse(new TextDecoder().decode(pt)), o.from);
			} catch {
				/* not ours, or tampered: dropped */
			}
		};
		ws.onclose = () => {
			if (this.ws !== ws) return;
			this.up = false;
			this.failures++;
			this.onState(false);
			if (!this.closed) setTimeout(() => this.ws === ws && !this.closed && this.connect(), Math.min(20, 2 * this.failures) * 1000);
		};
		clearInterval(this.ping);
		this.ping = window.setInterval(() => this.ws?.readyState === 1 && this.ws.send('{"type":"ping"}'), 20000);
	}

	/** False when the channel isn't open: the caller keeps the change and sends it on reconnect. */
	async send(msg: Record<string, unknown>, snap = false): Promise<boolean> {
		if (!this.up || this.ws?.readyState !== 1) return false;
		const iv = crypto.getRandomValues(new Uint8Array(12));
		const ct = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, await this.aes, enc.encode(JSON.stringify(msg))));
		this.ws.send(JSON.stringify({ from: this.me, box: toB64(new Uint8Array([...iv, ...ct])), snap }));
		return true;
	}

	retry() {
		this.failures = 0;
		const old = this.ws;
		this.ws = null;
		old?.close();
		void this.connect();
	}

	close() {
		this.closed = true;
		clearInterval(this.ping);
		this.ws?.close();
		this.ws = null;
	}
}
