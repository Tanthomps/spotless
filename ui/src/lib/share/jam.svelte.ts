// Jam on the Mac: the same protocol as the iPhone (JamStore) and the web page. The host's queue is
// the Jam's; it signs every state and "end" (ECDSA P-256, public key in the link), and guests only
// accept what verifies, carries this Jam's id and a rising sequence.
import * as api from '$lib/api';
import { auth, playback, toast } from '$lib/player.svelte';
import { Channel, RELAY, b64url, fromB64url, fromWire, parseFragment, shareMe, toWire, type WireSong } from './channel';

type Member = { id: string; name: string };
type State = { host: Member; items: WireSong[]; index: number; posMs: number; at: number; playing: boolean; members: Member[] };

export const jam = $state({
	role: null as 'host' | 'guest' | null,
	state: null as State | null,
	members: [] as Member[],
	connected: false,
	trouble: false,
	hostAway: false,
	link: '',
	open: false
});

let ch: Channel | null = null;
let signer: CryptoKeyPair | null = null;
let hostKey: CryptoKey | null = null;
let seq = 0,
	lastSeq = 0,
	lastSent = '',
	lastSentAt = 0,
	lastStateAt = 0;
let loop = 0,
	watchdog = 0;

const enc = new TextEncoder();
const toB64 = (u: Uint8Array) => btoa(String.fromCharCode(...u));

export function jamName(): string {
	const n = localStorage.getItem('share.name');
	if (n) return n;
	const acct = auth.account?.signedIn ? auth.account.name : '';
	return acct || 'Guest';
}
export const hasJamName = () => !!localStorage.getItem('share.name');
export function setJamName(n: string) {
	const name = n.trim().slice(0, 40);
	if (!name) return;
	localStorage.setItem('share.name', name);
	if (jam.role === 'host') {
		jam.members = jam.members.map((m) => (m.id === shareMe() ? { ...m, name } : m));
		void publish(true);
	} else if (jam.role === 'guest') void ch?.send({ t: 'hello', id: shareMe(), name });
}

function snapshot(): State | null {
	const q = playback.queue;
	if (!q?.items?.length) return null;
	return {
		host: { id: shareMe(), name: jamName() },
		items: q.items.map(toWire),
		index: q.currentIndex,
		posMs: playback.position * 1000,
		at: Date.now(),
		playing: !playback.paused,
		members: jam.members
	};
}

async function sendSigned(msg: Record<string, unknown>) {
	if (!signer || !ch) return;
	seq = Math.max(seq + 1, Date.now());
	const body = JSON.stringify({ ...msg, ch: ch.id, seq });
	const sig = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, signer.privateKey, enc.encode(body)));
	await ch.send({ t: 'signed', body, sig: toB64(sig) }, msg.t === 'state');
}

let lastPos = { pos: 0, at: 0 };
async function publish(force: boolean) {
	const s = snapshot();
	if (jam.role !== 'host' || !s) return;
	const key = `${s.items.map((i) => i.videoId)}|${s.index}|${s.playing}|${JSON.stringify(s.members)}`;
	const predicted = lastPos.pos + (s.playing ? Date.now() - lastPos.at : 0);
	const jumped = lastPos.at > 0 && Math.abs(s.posMs - predicted) > 3000;
	lastPos = { pos: s.posMs, at: Date.now() };
	if (!force && key === lastSent && !jumped && Date.now() - lastSentAt < 15000) return;
	lastSent = key;
	lastSentAt = Date.now();
	jam.state = s;
	await sendSigned({ ...s, t: 'state' });
}

function attach(c: Channel, role: 'host' | 'guest') {
	ch = c;
	jam.role = role;
	c.onMessage = (m, from) => (role === 'host' ? hostHandle(m, from) : guestHandle(m));
	c.onState = (up) => {
		jam.connected = up;
		jam.trouble = !up && c.failures >= 3;
		if (!up) return;
		if (role === 'guest') void c.send({ t: 'hello', id: shareMe(), name: jamName() });
		else void publish(true);
	};
	void c.connect();
}

export async function startJam() {
	if (jam.role) return;
	if (!playback.now) return toast('Play something first, then start a Jam');
	const c = Channel.make(shareMe());
	signer = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign', 'verify'])) as CryptoKeyPair;
	const pub = new Uint8Array(await crypto.subtle.exportKey('raw', signer.publicKey));
	jam.members = [{ id: shareMe(), name: jamName() }];
	jam.link = `${RELAY}/j#${c.fragment}&p=${b64url(pub)}`;
	attach(c, 'host');
	loop = window.setInterval(() => void publish(false), 1000);
	jam.open = true;
	toast('Jam started. Invite friends to listen together.');
}

function hostHandle(m: Record<string, unknown>, from: string) {
	const id = m.id as string | undefined;
	switch (m.t) {
		case 'hello': {
			if (!id || id !== from || id === shareMe()) return;
			const name = String(m.name ?? 'Guest').slice(0, 40);
			const i = jam.members.findIndex((x) => x.id === id);
			if (i >= 0) jam.members[i] = { id, name };
			else {
				jam.members = [...jam.members, { id, name }];
				toast(`${name} joined the Jam`);
			}
			return void publish(true);
		}
		case 'bye':
			if (!id || id !== from || id === shareMe()) return;
			jam.members = jam.members.filter((x) => x.id !== id);
			return void publish(true);
		case 'add':
			return void api.addToQueue([fromWire(m.song as WireSong)]).catch(() => {});
		case 'remove': {
			const q = playback.queue;
			const i = q.items.findLastIndex((s, n) => n > q.currentIndex && s.video_id === m.videoId);
			if (i >= 0) void api.removeFromQueue(i).catch(() => {});
			return;
		}
		case 'cmd':
			if (m.op === 'next') void api.nextTrack();
			else if (m.op === 'prev') void api.prevTrack();
			else if ((m.op === 'play') === playback.paused) void api.togglePause();
			return;
		case 'search':
			return void api
				.search(String(m.q ?? '').slice(0, 100))
				.then((r) => ch?.send({ t: 'results', rid: m.rid, items: r.slice(0, 12).map(toWire) }))
				.catch(() => {});
	}
}

async function verified(m: Record<string, unknown>): Promise<Record<string, unknown> | null> {
	if (m.t !== 'signed' || !hostKey || typeof m.body !== 'string' || typeof m.sig !== 'string') return null;
	try {
		const ok = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, hostKey, Uint8Array.from(atob(m.sig), (c) => c.charCodeAt(0)), enc.encode(m.body));
		if (!ok) return null;
		const b = JSON.parse(m.body);
		if (b.ch !== ch?.id || !(b.seq > lastSeq)) return null;
		lastSeq = b.seq;
		return b;
	} catch {
		return null;
	}
}

async function guestHandle(raw: Record<string, unknown>) {
	const m = await verified(raw);
	if (!m) return;
	if (m.t === 'state') {
		const s = m as unknown as State;
		const first = !jam.state;
		jam.state = s;
		jam.members = s.members;
		lastStateAt = Date.now();
		jam.hostAway = false;
		void follow(s);
		if (first) toast(`You joined ${s.host.name}'s Jam`);
	} else if (m.t === 'end') {
		toast(`${jam.state?.host.name ?? 'The host'} ended the Jam`);
		detach();
	}
}

/** Play what the host plays, where the host is. */
async function follow(s: State) {
	const cur = s.items[s.index];
	if (!cur) return;
	const want = (s.posMs + (s.playing ? Math.max(0, Date.now() - s.at) : 0)) / 1000;
	if (playback.now?.videoId !== cur.videoId) {
		await api.playPlaylist(s.items.map(fromWire), s.index).catch(() => {});
		// ponytail: seeks once the stream opens (~1 s); a slower resolve starts a little behind.
		setTimeout(() => void api.seek(want + 1.2).catch(() => {}), 1200);
		if (!s.playing) setTimeout(() => !playback.paused && void api.togglePause(), 1500);
		return;
	}
	if (Math.abs(playback.position - want) > 2.5) void api.seek(want).catch(() => {});
	if (s.playing === playback.paused) void api.togglePause();
}

export async function joinJam(fragment: string) {
	const p = parseFragment(fragment);
	const pub = p?.q.get('p');
	if (!p || !pub) return toast("That Jam link isn't complete.");
	try {
		hostKey = await crypto.subtle.importKey('raw', fromB64url(pub), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify']);
	} catch {
		return toast("That Jam link isn't complete.");
	}
	if (jam.role) leaveJam();
	const c = new Channel(p.id, p.key, shareMe());
	jam.link = `${RELAY}/j#${c.fragment}&p=${pub}`;
	attach(c, 'guest');
	lastStateAt = Date.now();
	watchdog = window.setInterval(() => {
		jam.hostAway = !!jam.state && Date.now() - lastStateAt > 45000;
	}, 5000);
	jam.open = true;
}

export function jamCommand(op: 'next' | 'prev' | 'play' | 'pause') {
	if (jam.role === 'host') {
		if (op === 'next') void api.nextTrack();
		else if (op === 'prev') void api.prevTrack();
		else void api.togglePause();
	} else void ch?.send({ t: 'cmd', op });
}

export function jamAdd(songs: api.SongItem[]) {
	if (jam.role === 'host') return void api.addToQueue(songs).catch(() => {});
	for (const s of songs) void ch?.send({ t: 'add', song: toWire(s) });
	toast(songs.length === 1 ? 'Added to the Jam' : `Added ${songs.length} songs to the Jam`);
}

export const jamRetry = () => {
	jam.trouble = false;
	ch?.retry();
};

export function leaveJam() {
	if (jam.role === 'host') void sendSigned({ t: 'end' });
	else void ch?.send({ t: 'bye', id: shareMe() });
	detach();
}

function detach() {
	clearInterval(loop);
	clearInterval(watchdog);
	const c = ch;
	setTimeout(() => c?.close(), 500);
	ch = null;
	signer = null;
	hostKey = null;
	lastSeq = 0;
	Object.assign(jam, { role: null, state: null, members: [], connected: false, trouble: false, hostAway: false, link: '', open: false });
}
