# Fortify plan (iOS app, every screen)

Audit 2026-11-20, code reading only (nothing run). Paths under `ios/Encore/Encore/`.
Already solid: plain-English error copy, `EntityLoadState` retry on most pages, optimistic likes/settings with rollback (`actions.run`), offline banner, Home skeletons + Reload, confirm-before-delete almost everywhere.

Shared fix used below: **keep-old-on-fail** = `if let p = try? await … { page = p } else { app.fail(...) }` instead of `page = try? await …`.

## P0: user stuck or work lost

| Screen | Problem | Fix |
|---|---|---|
| Playlist page | `page = try? await getPlaylist` on like/edit/touch (`Screens/EntityViews.swift:409,414,417`) wipes a loaded list into an endless spinner offline | keep-old-on-fail, and go through `app.loadPlaylist` (offline fallback) |
| New playlist / folder sheet | Sheet closes before `try? createPlaylist/createFolder` (`Screens/Folders.swift:220-229`): failure is silent and the typed name is gone | Keep sheet open with busy Create; on error `app.fail` and keep the name; disable while in flight |

## P1: broken experience

**Player**
- Lyrics card: load failure, loading and "no lyrics" all read "Lyrics aren't available" and never retry (`Shell/LyricsQueue.swift:10-11,74`) → track loading/failed; shimmer; "Couldn't load lyrics · Try again".
- Lyrics full view: blank with no lines (`Shell/LyricsQueue.swift:147`) → same states as the card.
- Save episode from Now Playing does nothing on error (`Shell/NowPlaying.swift:279`) → toast + busy.

**Library / Home**
- Library: no loading or error state; a failed first load looks like an empty library (`Screens/LibraryHome.swift:216`, `App/Stores.swift:169`) → `loaded/failed` on the store, `EntityLoadState` until first snapshot.
- Home Podcasts/Audiobooks chips: blank on load and on failure (`Screens/LibraryHome.swift:558`, `App/HomeStore.swift:70,75`) → reuse the All/Music phase logic (skeleton → failed + Reload).
- ShelfGrid podcast/audiobook categories: "Nothing here right now" while loading and on failure (`Screens/ShelfGrid.swift:53,68,74`) → `EntityLoadState`.

**Playlists**
- Long playlists silently stop at ~100 rows when paging fails (`Screens/PlaylistSmarts.swift:123,131`) → "Couldn't load more songs · Try again" row.
- Enhance + button double-adds on double tap (`Screens/PlaylistSmarts.swift:106`) → remove the row immediately.
- Edit playlist: load failure leaves an empty sheet with Save disabled forever (`Screens/PlaylistEdit.swift:122`) → `EntityLoadState`.
- Edit playlist: Cancel/swipe-down throws away edits silently (`Screens/PlaylistEdit.swift:95`) → "Discard changes?" + `interactiveDismissDisabled(changed)`.
- Add songs search: failure keeps old results, no spinner, no "No songs found" (`Screens/PlaylistEdit.swift:295`).
- Undo delete playlist is `try?` (`Screens/PlaylistEdit.swift:374`) → toast on failure, point to Recover playlists.
- ··· "Move to folder" toasts success before/regardless of the move (`Components/ActionSheet.swift:270-271`) → await, toast on result.
- ··· collection "Add to queue" silent on failure, always a no-op for artists (`Components/ActionSheet.swift:222-231`) → hide for artists, toast on failure.

**Search**
- Tab chips (Songs, Albums…) show skeletons forever after a failed load (`Screens/SearchView.swift:416-418,526`) → set `failed`, show "Couldn't load results · Try again".
- Top results blank while loading (`Screens/SearchView.swift:395-399`) → skeleton rows.
- `SearchResultsView` / `MoodView` have no loading/empty/error (`Screens/SearchView.swift:731,756`) → `EntityLoadState`.

**Audiobooks / Downloads / Devices**
- Audiobook download button only knows done/not done: no progress, no retry (`Screens/Audiobooks.swift:191,221`) → `DownloadButton` with `downloads.state("abook:<id>")`.
- Paused downloads (offline / waiting for Wi-Fi) freeze the ring with no reason (`Components/Downloads.swift:44-48`, `network.paused` unused) → paused glyph + "Waiting for Wi-Fi".
- `DownloadsRetryRow` is defined but never shown; failed glyph has no action (`Components/Downloads.swift:134-136`) → put it on Downloads and Storage pages.
- Devices Sync now and Unlink are `try?`, silent on failure (`App/DeviceSyncStore.swift:95-105`) → toast, keep state.

**Sign-in / Import**
- Google page fails to load (offline): blank sheet (`Screens/YouTubeSignIn.swift:356-359`) → "Couldn't reach Google" + Try again panel.
- Expired session refresh fails quietly; app still says signed in (`Screens/YouTubeSignIn.swift:119-122`) → "Your YouTube session ended. Sign in again."
- Multi-channel account: identities `try?` → `[]` leaves the user stuck on the YouTube page (`Screens/YouTubeSignIn.swift:75,254`, also `Screens/SettingsPages.swift:74`) → error panel + Try again.
- Import state lives only in memory; killed/backgrounded mid-import loses the job (`Screens/Import.swift:23-26`, `App/Stores.swift:507`) → check `importStatus` on open, jump to progress/review.
- Hidden import never says it's ready (`Screens/Import.swift:770`) → "Your import is ready to review" toast/banner.
- Empty profile preview: "0 of 0 selected" + disabled button, no reason (`Screens/Import.swift:111-115,602`) → explain and suggest a link or data file.
- Import Start has no busy/guard (`Screens/Import.swift:118-125,604`).
- Failed import shares cancelled copy, no reason, no retry (`Screens/Import.swift:808-816`).
- Review: check/choose errors never shown (`Screens/ImportReview.swift:146,158`) → inline error + Retry.
- Review Close X discards matches with no confirm (`Screens/Import.swift:344,354-363`) → confirm.

## P2: polish that costs trust

- Duplicate toast with the queue open (`Shell/RootView.swift:36-41` + `Shell/LyricsQueue.swift:392-398`).
- Play spinner never times out if the core hangs (`Shell/MiniPlayer.swift:60-61`) → ~15s "Taking too long · Retry".
- ±15s skip is `try?` (`Shell/NowPlaying.swift:348,355`, `Shell/NowPlayingVideo.swift:151,160`).
- Artist Follow (About card) not optimistic, invites double taps (`Shell/NowPlaying.swift:883`).
- Queue: multi-remove has no undo (`Shell/LyricsQueue.swift:548-551`); selection by index races queue changes (:273); suggestion Remove/Keep toast before result with no rollback (:494-504).
- Library "Start your library" empty state can never show (`Screens/LibraryHome.swift:336-344`).
- Home pull-to-refresh failure is silent (`App/HomeStore.swift:49`).
- Made For You "Save as playlist": double-tap makes two; partial failure leaves an empty playlist (`Screens/MadeForYou.swift:463-472`).
- Folder create double-tap (`Screens/Folders.swift:172,184`).
- History: one failed read hides data that loaded (`Screens/History.swift:276-279`).
- Stats and Charts: range/country switch has no spinner, failure silent, chip lies (`Screens/Stats.swift:288`, `Screens/Browse.swift:62`).
- Playlist sort by date silently falls back; sort save `try?` (`Screens/EntityViews.swift:441,450`).
- Artist with no songs: Play/Shuffle do nothing (`Screens/EntityViews.swift:793,796`).
- Enhance "not for me" `try?` (`Screens/PlaylistSmarts.swift:118`).
- Edit playlist save closes first; partial failure loses edits; no success toast (`Screens/PlaylistEdit.swift:177,185,210`).
- AddToPlaylist membership check failure only logged (`Screens/AddToPlaylist.swift:226-228`).
- Radio: save double-tap makes two playlists; undo `try?` (`Screens/RadioView.swift:181,193`).
- ··· Remove from folder / hide-undo silent (`Components/ActionSheet.swift:180,276`).
- Search empty top results and audiobook tab blank (`Screens/SearchView.swift:521-523`).
- Your Episodes empty message shows while loading/failed (`Screens/Podcasts.swift:652,665`); episode download failure leaves it saved (:32); a11y says "Downloading" when failed (:62).
- Audiobook with zero chapters (`Screens/Audiobooks.swift:77,160`).
- Device join has no client timeout and Back doesn't cancel (`App/DeviceSyncStore.swift:201,228-233`); pairing spinner can hang (:256).
- Storage full shows as generic failure; collection ring counts other downloads (`App/FeatureStores.swift:138`).
- Offline/cellular switches don't revert on failure (`Screens/SettingsPages.swift:257,262,294`); "Downloads removed" and "Cache cleared" toast before/regardless of result (:344,352).
- Podcast settings load failure disables switch with no reason; ad-free switch flips back silently (`Screens/SettingsPorted.swift:20,39,56`).
- Import polling loops forever at 0% on repeated failure (`Screens/Import.swift:151`); one bad link fails all (:88); 0 matched still shows a green check (`Screens/ImportReview.swift:238,251`); review search offline says "No songs found" (:527).

## P3

"1 songs" (`Screens/LibraryHome.swift:68`), toast 2-line cap (`Shell/RootView.swift:273`), empty queue/album/discography/MFY messages, artist About not expandable, Follow without toast, generic folder/stats error copy, deleted folder shows as "Folder", profile name no lineLimit, fake 32 GB free-space fallback, OPML export double-tap, launch retry shows no attempt count, Speed&Pitch rollback race, lyrics providers `try?`.

## Phases

1. P0 (2 fixes) + keep-old-on-fail everywhere a loaded page is replaced by `try?`.
2. P1 player + library + playlists.
3. P1 search, downloads, devices.
4. P1 sign-in + import.
5. P2 sweep: double-tap guards (one `inFlight` pattern), toast-after-result, reverts.
