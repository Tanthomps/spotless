<script lang="ts">
	/**
	 * "Playing on <device>": another linked device is playing and this one isn't (presence.rs).
	 * Play/pause and next go to that device; "Play here" picks the song up at its position.
	 */
	import { onMount } from 'svelte';
	import * as api from '$lib/api';
	import type { RemoteDevice } from '$lib/api';
	import { playback } from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';
	import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
	import DevicesIcon from 'phosphor-svelte/lib/DevicesIcon';

	let remotes = $state<RemoteDevice[]>([]);
	const active = $derived(remotes.find((r) => r.playing));
	const show = $derived(!!active && (!playback.now || playback.paused));

	onMount(() => {
		api.presenceList().then((r) => (remotes = r)).catch(() => {});
		const un = api.onPresenceChanged((r) => (remotes = r));
		return () => void un.then((f) => f());
	});

	function send(d: RemoteDevice, cmd: 'play' | 'pause' | 'next' | 'prev') {
		if (cmd === 'play' || cmd === 'pause') d.playing = cmd === 'play';
		api.presenceSend(d.dev, cmd).catch(() => {});
	}

	async function playHere(d: RemoteDevice) {
		if (!d.song) return;
		const elapsed = d.playing ? Math.max(0, Date.now() - (d.at ?? 0)) : 0;
		const song = { videoId: d.song.videoId, title: d.song.title, artists: d.song.artists, thumbnail: d.song.thumbnail ?? null } as api.SongItem;
		await api.playPlaylist([song], 0);
		// ponytail: seeks once the stream opens (~1 s); a resolve slower than that starts from the top.
		setTimeout(() => api.seek(((d.posMs ?? 0) + elapsed + 1200) / 1000).catch(() => {}), 1200);
		send(d, 'pause');
	}
</script>

{#if show && active}
	<div class="mx-2 mb-1 flex h-11 items-center gap-3 rounded-lg bg-[#0f3a22] px-2 text-white" data-testid="remote-device-bar">
		<img src={thumb(active.song?.thumbnail ?? '', 80)} alt="" class="size-8 rounded-sm object-cover" />
		<div class="min-w-0 flex-1 leading-tight">
			<div class="truncate text-[13px] font-bold">{active.song?.title}</div>
			<div class="flex items-center gap-1 truncate text-[12px] font-medium text-[var(--accent,#1ed760)]">
				<DevicesIcon size={12} /> Playing on {active.name}
			</div>
		</div>
		<button class="rounded-full px-3 py-1 text-[12px] font-bold hover:bg-white/10" onclick={() => playHere(active)}>Play here</button>
		<button aria-label={active.playing ? `Pause on ${active.name}` : `Play on ${active.name}`} class="grid size-8 place-items-center rounded-full hover:bg-white/10" onclick={() => send(active, active.playing ? 'pause' : 'play')}>
			{#if active.playing}<PauseIcon size={18} weight="fill" />{:else}<PlayIcon size={18} weight="fill" />{/if}
		</button>
		<button aria-label={`Next on ${active.name}`} class="grid size-8 place-items-center rounded-full hover:bg-white/10" onclick={() => send(active, 'next')}>
			<SkipForwardIcon size={18} weight="fill" />
		</button>
	</div>
{/if}
