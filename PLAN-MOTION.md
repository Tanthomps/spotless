# Motion plan (iOS app)

Audit 2026-11-20 against the 20 motion guidelines + 3 premium details. Grade: **Motion 11/18 (2 N/A) · Premium 1/3**.
All paths under `ios/Encore/Encore/`. Build and check each phase on the phone (`scripts/build-ipa.sh`, ~3 min).

## Phase 1: shared tokens (everything else uses these)

`Design/Tokens.swift` `Motion` (line 139):
- Add `exit`: same curve as `spring`, 0.8x the response (`.spring(response: 0.28, dampingFraction: 0.86)`), reduce = `.easeOut(0.14)`. (#15)
- Add `rowDelay(_ i: Int) -> Double` = `min(i, 10) * 0.03`, 0 when `reduce`. (#3)
- Add `blockDelay(_ i: Int) -> Double` = `min(i, 8) * 0.07`, 0 when `reduce`. (P2)
- Add `pop: AnyTransition` = opacity + `scale(0.95)` + blur 6 → 0. Reduce = `.opacity`. (#10, #18)
- Add a `Pulse` modifier: 1 → 1.04 → 1 over ~0.25s via `keyframeAnimator`, off under reduce. (#8, P3)

Done when: tokens compile, existing call sites unchanged.

## Phase 2: Now Playing as one element (#20, #15)

- `Shell/MiniPlayer.swift` + `Shell/NowPlaying.swift`: share a `@Namespace` from `RootView`; `matchedGeometryEffect(id: "np-art")` on the mini cover and the big cover so the artwork grows from the mini player instead of the sheet sliding over it.
- `Shell/NowPlaying.swift:31`: open with `Motion.spring`, close with `Motion.exit`.
- `Screens/Settings.swift:228` side menu: same open/close split.

Done when: on the phone, tapping the mini player shows the cover travel up as one image; closing is visibly quicker than opening.

## Phase 3: icons and pills (#18, #10)

- `Components/Components.swift:6` `Icon`: `Image(...)` is an asset, so `.contentTransition(.symbolEffect(.replace))` at `Shell/MiniPlayer.swift:51` does nothing. Add an `IconSwap(name:)` view that crossfades old/new with scale 0.8 + blur 4 (both at once). Use it for like/unlike, play/pause, shuffle/repeat.
- `Shell/NowPlaying.swift:168`, `Shell/LyricsQueue.swift:373`: pill transition `scale 0.9` → `Motion.pop`.
- `Screens/AddToPlaylist.swift:147`: check grows from 0 (`.scale`) → `Motion.pop` + `Pulse`.

Done when: tapping like on the mini player blends the two icons; no icon hard-cuts.

## Phase 4: stagger (#3, #6, P2)

- List rows (`Screens/EntityViews.swift` track list, `Screens/LibraryHome.swift` rows, `Screens/SearchView.swift` results): on first appear, opacity 0 → 1 + y 8 → 0 with `.delay(Motion.rowDelay(i))`. First load only, never on scroll recycle.
- Screen blocks (Home shelves `Screens/MadeForYou.swift`, entity header in `Screens/EntityViews.swift:182`): header, hero, then shelves at `Motion.blockDelay(i)`.
- Entity header details (#6): title, meta, action row follow the cover at +60ms each.

Done when: opening a playlist cascades header then rows; reopening a cached one still cascades once, scrolling does not re-animate.

## Phase 5: confirmations and reveals (P3, #17)

- Toast `Shell/RootView.swift:39`: enter with a spring at ~4% overshoot (`dampingFraction 0.75`) + blur 8 → 0 while travelling; exit stays `Motion.exit` with no overshoot.
- "Show more" expanders (`Screens/Audiobooks.swift:248`, `Screens/Podcasts.swift:351,504`, `Screens/Stats.swift:157`): reveal the new height with a top-to-bottom mask instead of a jump.

Done when: a "Pinned" toast lands with a small settle and a slight blur on the way in.

## Phase 6: loading and reduce motion

- Spinners → skeleton rows: `Screens/EntityViews.swift:243`, `Screens/CreditsSheet.swift:124`, `Screens/ImportReview.swift:314`, `Screens/PlaylistEdit.swift:301`, `Screens/EntityExtras.swift:113`.
- Route the hard-coded animations through `Motion` so Reduce Motion covers them: `Shell/NowPlaying.swift:140,547,621,650,728`, `Shell/NowPlayingVideo.swift:213`, `Components/Components.swift:254`.

Done when: with Reduce Motion on, nothing travels or scales; only quick fades remain.
