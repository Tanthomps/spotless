<script lang="ts">
	// The Jam panel and pill, the Mac's twin of the iPhone's JamSheet/JamPill: invite link, who's in,
	// what's up next, and Leave/End. Name prompt first if this Mac has never been named.
	import Modal from '$lib/kit/Modal.svelte';
	import { copyText } from '$lib/clipboard';
	import { toast } from '$lib/player.svelte';
	import { thumb } from '$lib/thumb';
	import { hasJamName, jam, jamCommand, jamName, jamRetry, leaveJam, setJamName } from './jam.svelte';
	import UsersThreeIcon from 'phosphor-svelte/lib/UsersThreeIcon';
	import CopyIcon from 'phosphor-svelte/lib/CopyIcon';
	import SkipBackIcon from 'phosphor-svelte/lib/SkipBackIcon';
	import SkipForwardIcon from 'phosphor-svelte/lib/SkipForwardIcon';
	import PlayIcon from 'phosphor-svelte/lib/PlayIcon';
	import PauseIcon from 'phosphor-svelte/lib/PauseIcon';

	let name = $state('');
	let named = $state(hasJamName());
	const s = $derived(jam.state);
	const now = $derived(s?.items[s.index]);
	const next = $derived(s ? s.items.slice(s.index + 1, s.index + 21) : []);
	const host = $derived(jam.role === 'host');

	function saveName(e: Event) {
		e.preventDefault();
		if (!name.trim()) return;
		setJamName(name);
		named = true;
	}
	async function copy() {
		await copyText(jam.link);
		toast('Jam link copied. Friends can join from Spotless or a browser.');
	}
</script>

{#if jam.role}
	<button
		type="button"
		class="glass fixed right-4 bottom-24 z-40 flex h-9 items-center gap-2 rounded-full px-3 text-[13px] font-bold text-white"
		onclick={() => (jam.open = true)}
	>
		<UsersThreeIcon size={16} weight="fill" class="text-accent" />
		{host ? 'Your Jam' : `${s?.host.name ?? 'Joining'}'s Jam`} · {jam.members.length}
		{#if !jam.connected}<span class="size-2 rounded-full bg-yellow-400" aria-label="Reconnecting"></span>{/if}
	</button>
{/if}

<Modal bind:open={jam.open} title={host ? 'Your Jam' : s ? `${s.host.name}'s Jam` : 'Joining Jam…'} width={460}>
	{#if !named}
		<form class="flex flex-col gap-3" onsubmit={saveName}>
			<p class="text-[14px] text-white/70">What should friends see you as?</p>
			<input bind:value={name} maxlength="40" placeholder={jamName()} class="h-10 rounded-md bg-white/10 px-3 text-white outline-none focus:ring-2 focus:ring-accent" />
			<button type="submit" disabled={!name.trim()} class="btn-white self-end">Save</button>
		</form>
	{:else}
		{#if jam.trouble}
			<div class="mb-3 flex items-center justify-between rounded-md bg-yellow-500/15 px-3 py-2 text-[13px]">
				Can't reach the Jam. <button class="font-bold underline" onclick={jamRetry}>Try again</button>
			</div>
		{:else if jam.hostAway}
			<div class="mb-3 rounded-md bg-white/10 px-3 py-2 text-[13px] text-white/80">The host seems to be away. Music keeps going here.</div>
		{/if}

		<div class="mb-4 flex gap-2">
			<input readonly value={jam.link} class="h-9 min-w-0 flex-1 truncate rounded-md bg-white/10 px-3 text-[12px] text-white/70" />
			<button class="btn-white flex items-center gap-1" onclick={copy}><CopyIcon size={14} /> Copy invite</button>
		</div>

		{#if now}
			<div class="mb-3 flex items-center gap-3">
				<img src={thumb(now.thumbnail ?? '', 96)} alt="" class="size-12 rounded object-cover" />
				<div class="min-w-0 flex-1">
					<div class="truncate font-bold">{now.title}</div>
					<div class="truncate text-[13px] text-white/60">{now.artists}</div>
				</div>
				<button aria-label="Previous" class="grid size-8 place-items-center rounded-full hover:bg-white/10" onclick={() => jamCommand('prev')}><SkipBackIcon size={18} weight="fill" /></button>
				<button aria-label={s?.playing ? 'Pause' : 'Play'} class="grid size-9 place-items-center rounded-full bg-white text-black" onclick={() => jamCommand(s?.playing ? 'pause' : 'play')}>
					{#if s?.playing}<PauseIcon size={18} weight="fill" />{:else}<PlayIcon size={18} weight="fill" />{/if}
				</button>
				<button aria-label="Next" class="grid size-8 place-items-center rounded-full hover:bg-white/10" onclick={() => jamCommand('next')}><SkipForwardIcon size={18} weight="fill" /></button>
			</div>
		{:else}
			<p class="mb-3 text-[13px] text-white/60">{host ? 'Play something to get the Jam going.' : 'Waiting for the host…'}</p>
		{/if}

		<h3 class="mb-1 text-[13px] font-bold text-white/60">In this Jam ({jam.members.length})</h3>
		<ul class="mb-3 flex flex-wrap gap-1.5">
			{#each jam.members as m (m.id)}<li class="truncate rounded-full bg-white/10 px-2.5 py-1 text-[12px]">{m.name}</li>{/each}
		</ul>

		{#if next.length}
			<h3 class="mb-1 text-[13px] font-bold text-white/60">Up next</h3>
			<ul class="max-h-56 overflow-y-auto">
				{#each next as t, i (i)}<li class="truncate py-1 text-[13px]">{t.title} <span class="text-white/50">· {t.artists}</span></li>{/each}
			</ul>
		{/if}
		{#if !host}<p class="mt-2 text-[12px] text-white/50">Right-click any song and pick Add to Jam.</p>{/if}
	{/if}
	{#snippet footer()}
		<button class="rounded-full px-4 py-2 text-[14px] font-bold text-red-400 hover:bg-white/10" onclick={leaveJam}>{host ? 'End Jam' : 'Leave Jam'}</button>
	{/snippet}
</Modal>
