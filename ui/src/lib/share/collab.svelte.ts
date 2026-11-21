// Collaborative playlists on the Mac, the same protocol as the iPhone's CollabStore: each member
// keeps an ordinary playlist; this diffs it against what the channel last agreed on (`known`),
// sends only what actually went out, and applies what others send.
// ponytail: keyed by videoId and order isn't shared, as on the iPhone.
import * as api from '$lib/api';
import { toast } from '$lib/player.svelte';
import { copyText } from '$lib/clipboard';
import { Channel, RELAY, b64url, fromB64url, fromWire, parseFragment, shareMe, toWire, type WireSong } from './channel';

type Link = { playlistId: string; channel: string; key: string; known: string[]; cursor?: number };
const KEY = 'collab.links';

function load(): Record<string, Link> {
	try {
		return JSON.parse(localStorage.getItem(KEY) ?? '{}');
	} catch {
		return {};
	}
}
export const collab = $state({ links: load() });
const save = () => localStorage.setItem(KEY, JSON.stringify(collab.links));
const channels = new Map<string, Channel>();
const busy = new Set<string>();

export const isCollab = (playlistId: string) => !!collab.links[playlistId];

export function inviteLink(playlistId: string, name: string) {
	const l = collab.links[playlistId];
	return l ? `${RELAY}/p#c=${l.channel}&k=${l.key}&n=${encodeURIComponent(name)}` : null;
}

function wire(c: Channel, playlistId: string) {
	channels.set(playlistId, c);
	c.lastId = collab.links[playlistId]?.cursor ?? 0;
	c.onMessage = (m) => void apply(m, playlistId);
	c.onState = (up) => up && void push(playlistId);
	c.onCursor = (n) => {
		const l = collab.links[playlistId];
		if (l) {
			l.cursor = n;
			save();
		}
	};
	void c.connect();
}

/** Make an own playlist collaborative; answers the invite link. */
export async function sharePlaylist(playlistId: string, name: string): Promise<string | null> {
	if (!collab.links[playlistId]) {
		const page = await api.getPlaylist(playlistId).catch(() => null);
		if (!page) {
			toast("Couldn't open that playlist");
			return null;
		}
		const c = Channel.make(shareMe());
		collab.links[playlistId] = { playlistId, channel: c.id, key: b64url(c.key), known: page.items.map((s) => s.video_id) };
		save();
		wire(c, playlistId);
		const snap = () => c.send({ t: 'snap', name, songs: page.items.map(toWire) }, true);
		// The first snapshot goes as soon as the socket is up.
		const tryIt = async (n = 0) => (await snap()) || (n < 20 && setTimeout(() => tryIt(n + 1), 500));
		void tryIt();
	}
	return inviteLink(playlistId, name);
}

/** Share (if not yet) and copy the invite link. */
export async function inviteCollab(playlistId: string, name: string) {
	const link = await sharePlaylist(playlistId, name);
	if (!link) return;
	await copyText(link);
	toast('Invite link copied. Anyone with it can add and remove songs.');
}

export async function joinCollab(fragment: string) {
	const p = parseFragment(fragment);
	if (!p) return toast("That playlist link isn't complete.");
	const existing = Object.values(collab.links).find((l) => l.channel === p.id);
	if (existing) return existing.playlistId;
	const name = p.q.get('n') || 'Collaborative playlist';
	const id = await api.createPlaylist(name, true).catch(() => null);
	if (!id) return toast("Couldn't create the playlist");
	collab.links[id] = { playlistId: id, channel: p.id, key: b64url(p.key), known: [] };
	save();
	wire(new Channel(p.id, p.key, shareMe()), id);
	toast(`Joining ${name}…`);
	setTimeout(() => {
		if (!collab.links[id] || collab.links[id].cursor) return;
		toast(channels.get(id)?.up ? `Nothing in ${name} yet. Songs appear as others add them.` : `Couldn't load ${name}. Check your connection.`);
	}, 12000);
	return id;
}

async function apply(m: Record<string, unknown>, playlistId: string) {
	const l = collab.links[playlistId];
	if (!l) return;
	const channel = l.channel;
	let known = [...l.known];
	if (m.t === 'snap') {
		const songs = ((m.songs as WireSong[]) ?? []).filter((s) => s?.videoId);
		const have = new Set((await api.getPlaylist(playlistId).catch(() => null))?.items.map((s) => s.video_id) ?? []);
		const missing = songs.filter((s) => !have.has(s.videoId)).map(fromWire);
		if (missing.length) await api.libPlaylistAdd(playlistId, missing).catch(() => {});
		known = [...new Set([...known, ...songs.map((s) => s.videoId)])];
	} else if (m.t === 'add') {
		const s = m.song as WireSong;
		if (!s?.videoId || known.includes(s.videoId)) return;
		await api.libPlaylistAdd(playlistId, [fromWire(s)]).catch(() => {});
		known.push(s.videoId);
	} else if (m.t === 'remove' && typeof m.videoId === 'string') {
		await api.libPlaylistRemoveVideos(playlistId, [m.videoId]).catch(() => {});
		known = known.filter((v) => v !== m.videoId);
	} else return;
	const cur = collab.links[playlistId];
	if (!cur || cur.channel !== channel) return; // left while the core was busy
	cur.known = known;
	save();
}

/** This Mac's changes, out. Only what was sent counts as shared; the rest goes next time. */
export async function push(playlistId: string) {
	const l = collab.links[playlistId];
	const c = channels.get(playlistId);
	if (!l || !c || busy.has(playlistId)) return;
	busy.add(playlistId);
	try {
		const channel = l.channel;
		const page = await api.getPlaylist(playlistId).catch(() => null);
		if (!page || collab.links[playlistId]?.channel !== channel) return;
		const now = page.items.map((s) => s.video_id);
		const nowSet = new Set(now);
		const shared = new Set(l.known);
		for (const s of page.items) if (!shared.has(s.video_id) && (await c.send({ t: 'add', song: toWire(s) }))) shared.add(s.video_id);
		for (const v of l.known) if (!nowSet.has(v) && (await c.send({ t: 'remove', videoId: v }))) shared.delete(v);
		const cur = collab.links[playlistId];
		if (!cur || cur.channel !== channel) return;
		cur.known = [...now.filter((v) => shared.has(v)), ...[...shared].filter((v) => !nowSet.has(v))];
		save();
	} finally {
		busy.delete(playlistId);
	}
}

export function leaveCollab(playlistId: string) {
	channels.get(playlistId)?.close();
	channels.delete(playlistId);
	delete collab.links[playlistId];
	save();
}

/** Connect every collaborative playlist and push what changed; then keep up with library edits. */
export function startCollab() {
	for (const l of Object.values(collab.links)) {
		if (channels.has(l.playlistId)) continue;
		wire(new Channel(l.channel, fromB64url(l.key), shareMe()), l.playlistId);
	}
	void api.onLibraryChanged(() => {
		for (const id of Object.keys(collab.links)) void push(id);
	});
}
