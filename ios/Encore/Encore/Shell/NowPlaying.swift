// Now Playing: a full-screen cover that slides up over the shell and follows the finger down to
// dismiss. First page = header, artwork, title + like, scrubber, controls, devices/share/queue.
// Scrolling reveals the lyrics card, About the artist, Credits and Next in queue.
import SwiftUI

struct NowPlayingCover: View {
    /// Under a parent that ignores the safe area the reader reports 0 on a real phone, which put the
    /// header under the Dynamic Island: take the window's own insets when they are larger.
    static func safeInsets(_ e: EdgeInsets) -> EdgeInsets {
        let w = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.safeAreaInsets ?? .zero
        return EdgeInsets(top: max(e.top, w.top), leading: max(e.leading, w.left), bottom: max(e.bottom, w.bottom), trailing: max(e.trailing, w.right))
    }
    static let openAnimation = Animation.spring(response: 0.42, dampingFraction: 0.9)
    static let closeAnimation = Animation.spring(response: 0.34, dampingFraction: 0.9)
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height + geo.safeAreaInsets.top + geo.safeAreaInsets.bottom
            // Landscape (the full-screen video): the side insets too, so the picture is centred.
            let w = geo.size.width + geo.safeAreaInsets.leading + geo.safeAreaInsets.trailing
            let open = app.router.nowPlayingOpen && app.player.hasTrack
            // The video full screen (Spotify): tap the video, or turn the phone (`VideoStore`).
            let fullscreen = open && VideoStore.shared.fullscreen
            ZStack {
                if app.player.hasTrack {
                    NowPlayingView(drag: $drag, screenHeight: h, insets: Self.safeInsets(geo.safeAreaInsets))
                        .opacity(fullscreen ? 0 : 1)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { ArtFlight.shared.npSheetY = $0 }
                }
                if fullscreen { VideoFullscreen() }
            }
            .onChange(of: geo.size.width > geo.size.height) { _, l in VideoStore.shared.rotated(landscape: l) }
            .frame(width: w, height: h)
            // Reduce Motion: Now Playing fades in place instead of sliding up.
            .offset(y: open ? max(0, drag) : (reduceMotion ? 0 : h))
            .opacity(reduceMotion && !open ? 0 : 1)
            // Closing is quicker than opening (0.8x).
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : open ? Self.openAnimation : Self.closeAnimation, value: open)
            .ignoresSafeArea()
        }
        .onChange(of: drag) { _, d in ArtFlight.shared.drag = d }
        .allowsHitTesting(app.router.nowPlayingOpen)
        .accessibilityHidden(!app.router.nowPlayingOpen)
        .onAppear { VideoStore.shared.attach(app) }
    }
}

private struct ScrollTopKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct NowPlayingView: View {
    @Environment(AppModel.self) private var app
    @Binding var drag: CGFloat
    let screenHeight: CGFloat
    var insets = EdgeInsets()
    @State private var accent: UIColor?
    @State private var overscroll: CGFloat = 0
    @State private var dragging = false
    @State private var startedAtTop = false
    @State private var artist: ArtistPage?
    /// Small dark pill over the controls ("Smart Shuffle is on").
    @State private var pill: String?
    @State private var pillTask: Task<Void, Never>?
    @State private var savingEpisode = false
    /// Spotify: a screenshot on Now Playing raises the song's share card.
    @State private var shareCard: SongItem?

    private var player: PlayerStore { app.player }
    /// Spotify mutes the cover's colour hard (a bright teal cover gives a dark teal page).
    private var bg: Color { accent?.surface(value: 0.36, maxSaturation: 0.5) ?? Color(hex: "#3a3a3a") }

    var body: some View {
        GeometryReader { geo in
          ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Space.l) {
                    mainPage(safeTop: insets.top, height: screenHeight - insets.bottom)
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ScrollTopKey.self, value: g.frame(in: .named("np")).minY)
                        })
                    // stream: pod-fixes — an episode has no lyrics: its chapters and description.
                    // stream: audiobooks — a book chapter also shows the book's chapter list.
                    VStack(spacing: Space.l) {
                        if player.showsLyrics { LyricsCard(accent: accent) } else { ChaptersCard(); BookChaptersCard(); EpisodeAboutCard() }
                    }
                    .id("cards")
                    if let artist { AboutArtistCard(artist: artist) }
                    CreditsCard()
                    NextInQueueCard()
                }
                .padding(.bottom, 40 + insets.bottom)
            }
            .coordinateSpace(name: "np")
            .onPreferenceChange(ScrollTopKey.self) { overscroll = max(0, $0) }
            .simultaneousGesture(dismissDrag)
            .background {
                LinearGradient(stops: [.init(color: bg, location: 0), .init(color: bg.opacity(0.85), location: 0.45),
                                       .init(color: Color(hex: "#121212"), location: 1.0)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.6), value: accent)
            }
            .onChange(of: app.router.npShowCards) { _, _ in withAnimation { proxy.scrollTo("cards", anchor: UnitPoint(x: 0.5, y: 0.12)) } }
          }
        }
        .background(Color(hex: "#121212").ignoresSafeArea())
        .clipShape(RoundedRectangle(cornerRadius: drag > 0 ? 40 : 0, style: .continuous))
        .artAccent(player.current?.thumbnail ?? player.now?.thumbnail, into: $accent)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            if let s = player.current, s.isEpisode != true, shareCard == nil { shareCard = s }
        }
        .sheet(item: $shareCard) { s in
            ShareCardSheet(song: s, accent: accent).environment(app)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("now-playing")
        .overlay {
            if app.router.lyricsOpen && player.showsLyrics { LyricsFullView(accent: accent, insets: insets).transition(Motion.slide(.bottom)) }
        }
        .overlay {
            if app.router.queueOpen { QueueView(insets: insets).transition(Motion.slide(.bottom)) }
        }
        .animation(Motion.spring, value: app.router.lyricsOpen)
        .animation(Motion.spring, value: app.router.queueOpen)
        .task(id: player.current?.isEpisode == true ? player.current?.videoId : nil) {
            // stream: chapters — beside playback, never before it.
            guard let s = player.current, s.isEpisode == true else { return }
            await app.podcasts.loadChapters(s.videoId, duration: player.duration)
        }
        .task(id: player.now?.artistId ?? player.current?.artistId) {
            guard let id = player.now?.artistId ?? player.current?.artistId else { artist = nil; return }
            artist = try? await app.core.getArtist(id: id)
        }
    }

    /// Follows the finger while the scroll view is at its top; the scroll view's own rubber-band
    /// (`overscroll`) is subtracted so the page moves exactly with the finger.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .global)
            .onChanged { v in
                if !dragging {
                    dragging = true
                    startedAtTop = overscroll >= -1 && v.translation.height > 0 && abs(v.translation.height) > abs(v.translation.width)
                }
                guard startedAtTop else { return }
                drag = max(0, v.translation.height - overscroll)
            }
            .onEnded { v in
                defer { dragging = false; startedAtTop = false }
                guard startedAtTop else { return }
                // Spotify: commits past ~25 % of the height or a downward flick faster than ~800 pt/s.
                let shouldClose = v.translation.height > screenHeight * 0.25 || v.velocity.height > 800
                if shouldClose {
                    app.router.nowPlayingOpen = false
                    Task { try? await Task.sleep(nanoseconds: 450_000_000); drag = 0 }
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { drag = 0 }
                }
            }
    }

    // MARK: first page

    /// Spotify's first page, measured on an iPhone 15 Pro Max (430 × 932 pt): header centre 24 under
    /// the status bar, cover 24 pt from each side, video pill 52 under it, title, scrubber, controls
    /// and the device/share/queue row at fixed gaps, the lyrics card peeking right after. On a shorter
    /// phone the gaps (not the cover) shrink in proportion.
    private func mainPage(safeTop: CGFloat, height: CGFloat) -> some View {
        let song = player.current
        let art = UIScreen.main.bounds.width - Space.xl * 2
        // header 48 · pill 32 · title 51 · scrubber 37 · controls 64 · bottom row 44
        let fixed: CGFloat = 276
        let gaps: CGFloat = 149.5
        let room = height - safeTop - 32 - fixed - art
        let k = min(1.4, max(0.4, room / gaps))
        return VStack(spacing: 0) {
            header.frame(height: 48)
            Color.clear.frame(height: 51.4 * k)
            // A music video / video podcast replaces the cover; the pill switches between them (stream
            // ios-video). Either one swipes to the neighbour; a tap on the video shows its controls.
            NPArtwork(fallback: song?.thumbnail ?? player.now?.thumbnail, video: VideoStore.shared.showsVideo)
                .frame(width: art, height: art)
            Color.clear.frame(height: 52.6 * k)
            // The pill's slot is kept when there is no video, so the title never jumps between songs.
            Group {
                if VideoStore.shared.canSwitch { NPVideoSwitch() } else { Color.clear }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 32)
            Color.clear.frame(height: 9.5 * k)
            titleRow(song)
            Color.clear.frame(height: 11 * k)
            Scrubber()
            Color.clear.frame(height: 17.7 * k)
            controls
                .padding(.horizontal, -6)
                .overlay(alignment: .top) {
                    if let pill {
                        Text(pill).font(Typo.font(13, .semibold)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 12).frame(height: 30)
                            .glassCapsule()
                            .offset(y: -40)
                            .transition(Motion.pop)
                            .accessibilityIdentifier("np-pill")
                    }
                }
            Color.clear.frame(height: 7.3 * k)
            bottomRow
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, safeTop)
        // The lyrics card starts 5 pt under the bottom row (the cards' own 16 pt spacing taken back).
        .padding(.bottom, 5 - Space.l)
    }

    private var header: some View {
        HStack {
            Button { close() } label: {
                Icon(name: "caret-down", size: 24).foregroundStyle(Palette.text).frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close Now Playing")
            .accessibilityIdentifier("np-close")
            Spacer()
            // Spotify: just the context's name, 15/700, centred; tap opens the context page.
            Button { openContext() } label: {
                VStack(spacing: 1) {
                    let name = player.queue.sourceName ?? player.now?.album ?? ""
                    Text(name.isEmpty ? contextLabel.capitalized : name).font(Typo.font(15, .bold)).foregroundStyle(Palette.text)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("np-context")
            Spacer()
            Button {
                Haptics.impact(.medium)
                if let s = player.current { app.sheet = .track(s, context: nil) }
            } label: {
                Icon(name: "dots-three", size: 24).foregroundStyle(Palette.text).frame(width: 44, height: 44)
            }
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, -10)
    }

    /// The page the queue plays from: Now Playing closes and the page pushes (Spotify).
    private func openContext() {
        guard let id = player.queue.sourceId, player.current?.isEpisode != true else { return }
        let route: Route
        if id == likedPlaylistId { route = .liked }
        else if id.hasPrefix("MPRE") { route = .album(id) }
        else if id.hasPrefix("UC") { route = .artist(id) }
        else if id.hasPrefix("VL") || id.hasPrefix("LOCALPLAYLIST") || id.hasPrefix("RD") || id.hasPrefix("MFY") { route = .playlist(id) }
        else { return }
        app.router.nowPlayingOpen = false
        app.router.push(route)
    }

    private func openArtist(_ song: SongItem?) {
        guard let a = song?.artistId ?? song?.artistRuns?.first(where: { $0.id != nil })?.id ?? player.now?.artistId else { return }
        app.router.nowPlayingOpen = false
        app.router.push(.artist(a))
    }

    private var contextLabel: String {
        if player.contextKind == .audiobook && player.current?.isEpisode == true { return "PLAYING FROM AUDIOBOOK" }
        if player.current?.isEpisode == true { return "PLAYING FROM PODCAST" }
        // A single pick has no context: from search it names the query, anything else (a Home
        // card, a link) just says what is playing.
        guard let id = player.queue.sourceId else {
            return player.queue.sourceName == nil ? "NOW PLAYING" : "PLAYING FROM SEARCH"
        }
        if id == likedPlaylistId || id.hasPrefix("VL") || id.hasPrefix("LOCALPLAYLIST") { return "PLAYING FROM PLAYLIST" }
        if id.hasPrefix("MPRE") { return "PLAYING FROM ALBUM" }
        if id.hasPrefix("UC") { return "PLAYING FROM ARTIST" }
        return "PLAYING FROM PLAYLIST"
    }

    /// stream: chapters. The chapter playing in this episode, if it has chapters.
    private func currentChapter(_ song: SongItem?) -> PodcastChapter? {
        guard let s = song, s.isEpisode == true, let list = app.podcasts.chapters[s.videoId] else { return nil }
        let i = chapterAt(list, player.position)
        return list.indices.contains(i) ? list[i] : nil
    }

    private func titleRow(_ song: SongItem?) -> some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Marquee(text: song?.title ?? player.now?.title ?? "", font: Typo.npTitle)
                    .accessibilityValue(song?.title ?? player.now?.title ?? "")
                    .accessibilityIdentifier("np-title")
                Text(song?.artists ?? player.now?.artists ?? "").font(Typo.npArtist).foregroundStyle(Palette.text.opacity(0.7)).lineLimit(1)
                    .onTapGesture { if song?.isEpisode != true { openArtist(song) } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier("np-artist")
                if let c = currentChapter(song) {
                    // A tap opens the Chapters sheet (Spotify).
                    Text(c.title).font(Typo.npArtist).foregroundStyle(Palette.text).lineLimit(1)
                        .onTapGesture { app.sheet = .chapters }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint("Shows all chapters")
                        .accessibilityIdentifier("np-chapter")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(song?.videoId)
            .transition(.opacity)
            if let s = song, s.isEpisode == true {
                // Episodes: + saves to Your Episodes (not Liked Songs).
                let saved = app.podcasts.saved.contains { $0.id == s.videoId }
                Button {
                    guard !savingEpisode else { return }
                    savingEpisode = true
                    Task {
                        defer { savingEpisode = false }
                        let e: PodcastEpisode
                        do { e = try await app.core.podcastEpisode(id: s.videoId) } catch {
                            app.fail(friendlyError(error, saved ? "Couldn't remove this episode" : "Couldn't save this episode"))
                            return
                        }
                        let on = app.podcasts.toggleSaved(e)
                        Haptics.impact(.light)
                        app.showToast(on ? "Added to Your Episodes" : "Removed from Your Episodes")
                    }
                } label: {
                    IconSwap(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 36)
                        .foregroundStyle(saved ? Palette.accent : Palette.text).pulse(on: saved)
                }
                .accessibilityLabel(saved ? "Remove from Your Episodes" : "Add to Your Episodes")
                .accessibilityIdentifier("np-like")
            } else if let s = song {
                let liked = app.library.isLiked(s.videoId)
                Button { app.likeButton(s) } label: {
                    IconSwap(name: liked ? "check-circle" : "plus-circle", fill: liked, size: 36)
                        .foregroundStyle(liked ? Palette.accent : Palette.text)
                        .pulse(on: liked)
                }
                .accessibilityLabel(liked ? "Saved in Liked Songs" : "Add to Liked Songs")
                    .accessibilityHint(liked ? "Opens Add to playlist" : "")
                .accessibilityIdentifier("np-like")
            }
        }
    }

    @ViewBuilder private var controls: some View {
        if player.current?.isEpisode == true { episodeControls } else { musicControls }
    }

    private var smartOn: Bool {
        app.settings.smartShuffle.on && (app.settings.smartShuffle.sourceId == nil || app.settings.smartShuffle.sourceId == player.queue.sourceId)
    }

    /// Spotify's cycle: off → shuffle → Smart Shuffle → off in own playlists / Liked Songs; elsewhere off ↔ shuffle.
    private func cycleShuffle() {
        let src = player.queue.sourceId ?? ""
        let own = src.hasPrefix("LOCALPLAYLIST:") || src == likedPlaylistId
        Task {
            if smartOn {
                _ = await app.settings.setSmartShuffle(false)
                showPill("Smart Shuffle is off")
            } else if player.shuffle {
                if own, await app.settings.setSmartShuffle(true) { showPill("Smart Shuffle is on") } else { player.toggleShuffle() }
            } else {
                player.toggleShuffle()
            }
        }
    }

    private func showPill(_ text: String) {
        withAnimation(Motion.quick) { pill = text }
        pillTask?.cancel()
        pillTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(Motion.quick) { pill = nil }
        }
    }

    /// Episodes: speed · back 15 · play · forward 15 · sleep timer (Spotify's podcast player).
    private var episodeControls: some View {
        HStack {
            Button { app.sheet = .speed } label: {
                Text(speedLabel(app.settings.speed)).font(Typo.font(15, .bold)).foregroundStyle(Palette.text)
                    .frame(width: 44, height: 52)
            }
            .accessibilityLabel("Playback speed \(speedLabel(app.settings.speed))")
            .accessibilityIdentifier("np-speed")
            Spacer()
            Button { app.player.seekBy(-15) } label: { SkipSeconds(forward: false) }
                .accessibilityLabel("Back 15 seconds")
                .accessibilityIdentifier("np-back15")
            Spacer()
            PlayCircleButton(playing: !player.paused, size: Metrics.npPlayButton, color: .white, loading: player.loading) { player.togglePause() }
                .accessibilityIdentifier("np-play")
            Spacer()
            Button { app.player.seekBy(15) } label: { SkipSeconds(forward: true) }
                .accessibilityLabel("Forward 15 seconds")
                .accessibilityIdentifier("np-fwd15")
            Spacer()
            Button { app.sheet = .sleepTimer } label: {
                ToggleIcon(name: "timer", on: app.settings.sleep.mode != nil, size: 26)
            }
            .accessibilityLabel("Sleep timer")
        }
        .buttonStyle(PressScale(scale: 0.9))
    }

    private var musicControls: some View {
        HStack {
            Button { cycleShuffle() } label: {
                ToggleIcon(name: "shuffle", on: player.shuffle || smartOn, size: 28)
                    .overlay(alignment: .topTrailing) {
                        if smartOn {
                            Icon(name: "sparkle", fill: true, size: 11).foregroundStyle(Palette.accent).offset(x: -6, y: 8)
                        }
                    }
            }
            .accessibilityLabel(smartOn ? "Disable Smart Shuffle" : player.shuffle ? "Enable Smart Shuffle" : "Shuffle")
            .accessibilityIdentifier("np-shuffle")
            Spacer()
            Button { player.skipPrevious() } label: {
                Icon(name: "skip-back", fill: true, size: 32).foregroundStyle(Palette.text).frame(width: 52, height: 52)
            }
            .accessibilityLabel("Previous")
            Spacer()
            PlayCircleButton(playing: !player.paused, size: Metrics.npPlayButton, color: .white, loading: player.loading) { player.togglePause() }
                .accessibilityIdentifier("np-play")
            Spacer()
            Button { player.skipNext() } label: {
                Icon(name: "skip-forward", fill: true, size: 32).foregroundStyle(Palette.text).frame(width: 52, height: 52)
            }
            .accessibilityLabel("Next")
            .accessibilityIdentifier("np-next")
            Spacer()
            Button { player.cycleRepeat() } label: {
                ToggleIcon(name: player.repeatMode == .one ? "repeat-once" : "repeat", on: player.repeatMode != .off, size: 28)
            }
            .accessibilityLabel("Repeat")
        }
        .buttonStyle(PressScale(scale: 0.9))
    }

    /// Devices (left) · share, queue (right): 20 pt icons in 44 pt hit areas.
    private var bottomRow: some View {
        HStack(spacing: 0) {
            // Accent glyph plus the device's name in accent while the audio plays elsewhere (Spotify).
            let device = AudioRoute.shared.externalName
            HStack(spacing: 6) {
                Icon(name: "devices", size: 22).foregroundStyle(device == nil ? Palette.text.opacity(0.85) : Palette.accent)
                    .frame(width: 22, height: 44)
                if let device {
                    Text(device).font(Typo.font(12, .bold)).foregroundStyle(Palette.accentText).lineLimit(1)
                        .accessibilityIdentifier("np-device")
                }
            }
            .frame(minWidth: 44, minHeight: 44, alignment: .leading)
            .routePickerOverlay()
            Spacer(minLength: Space.m)
            Button { if let s = app.player.current { ShareSheet.present(.song(s), app: app) } } label: {
                Icon(name: "export", size: 24).foregroundStyle(Palette.text.opacity(0.85)).frame(width: 44, height: 44)
            }
                .accessibilityLabel("Share")
                .accessibilityIdentifier("np-share")
                .padding(.trailing, 3.5)
            // Spotify: queue flush with the cover's right edge, share 47 pt to its left (centre to centre).
            Button { app.router.queueOpen = true } label: {
                Icon(name: "queue", size: 22).foregroundStyle(Palette.text.opacity(0.85)).frame(width: 32, height: 44, alignment: .trailing)
                    .contentShape(Rectangle().inset(by: -6))
            }
                .accessibilityLabel("Queue")
                .accessibilityIdentifier("np-queue")
        }
        .frame(height: 44)
    }

    private func close() {
        app.router.nowPlayingOpen = false
    }
}

/// Circular arrow with "15" inside: Spotify's podcast skip glyphs.
struct SkipSeconds: View {
    let forward: Bool
    var body: some View {
        Icon(name: forward ? "arrow-clockwise" : "arrow-counter-clockwise", size: 36).foregroundStyle(Palette.text)
            .overlay(Text("15").font(Typo.font(10, .bold)).foregroundStyle(Palette.text).offset(y: 1))
            .frame(width: 52, height: 52)
    }
}

/// Toggle glyph with the accent active colour and the 4pt dot underneath.
struct ToggleIcon: View {
    let name: String
    let on: Bool
    var size: CGFloat = 24
    var body: some View {
        VStack(spacing: 3) {
            IconSwap(name: name, size: size).foregroundStyle(on ? Palette.accent : Palette.text)
            Circle().fill(on ? Palette.accent : .clear).frame(width: 4, height: 4)
        }
        .frame(width: 44, height: 52)
        .offset(y: 4)
    }
}

/// Large square artwork as a carousel (Spotify): the previous and next covers wait just off
/// screen; the strip follows the finger 1:1; letting go past 30 % of the width, or with a flick,
/// slides the neighbour in and plays it. Swiping right plays the **previous track** (never a
/// restart); at either end of the queue it rubber-bands. Next / Previous from elsewhere slide too.
/// With `video`, the current slot is the video (16:9): a tap shows its controls (`NPVideoChrome`),
/// whose expand arrows open full screen (Spotify).
struct NPArtwork: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Used when there's no queue item (a podcast resume before the queue loads).
    let fallback: String?
    let video: Bool
    @State private var dx: CGFloat = 0
    @State private var axis: Axis?
    /// Set while a swipe has committed and the core hasn't moved the queue yet.
    @State private var pending = false
    /// The queue index the strip is centred on; follows the queue, in one step with `dx` after a swipe.
    @State private var shown: Int?
    @State private var width: CGFloat = 342
    /// The video's controls are up (a tap on the video; they hide after 3 s or on a second tap).
    @State private var chrome = false

    /// Space between neighbouring covers: the screen margins either side, so they rest just off it.
    static let spacing: CGFloat = Space.xl * 2

    private var player: PlayerStore { app.player }

    /// `peek`: a drag already this far along (snapshot tests of the neighbour peeking in).
    /// `chrome`: the video's controls already up (snapshot tests).
    init(fallback: String?, video: Bool = false, peek: CGFloat = 0, chrome: Bool = false) {
        self.fallback = fallback
        self.video = video
        _dx = State(initialValue: peek)
        _chrome = State(initialValue: chrome)
    }

    // Split into three pieces: one long modifier chain is more than newer Xcode can type-check in time.
    var body: some View {
        accessible
            // Over the 16:9 box in the middle of the square slot, following a swipe.
            .overlay {
                if video && chrome {
                    GeometryReader { geo in
                        let w: CGFloat = geo.size.width
                        let h: CGFloat = w * 9 / 16
                        let x: CGFloat = w / 2 + dx
                        let y: CGFloat = geo.size.height / 2
                        NPVideoChrome(expand: expand)
                            .frame(width: w, height: h)
                            .position(x: x, y: y)
                    }
                    .transition(.opacity)
                }
            }
            .task(id: chrome) {
                guard chrome else { return }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) { chrome = false }
            }
            .onChange(of: video) { _, on in if !on { chrome = false } }
    }

    /// The cover strip with its tap and swipe handling.
    private var covers: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    strip(width: geo.size.width)
                }
                .opacity(ArtFlight.shared.flying && !video ? 0 : 1)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ArtFlight.shared.npArt = $0 }
            .contentShape(Rectangle())
            .onTapGesture { if video { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } } }
            .gesture(swipe)
            .onChange(of: player.queue.currentIndex) { _, i in
                if pending {
                    // A committed swipe: the neighbour is already centred; re-centre on it in the same
                    // frame as dx goes back to 0, so nothing moves.
                    pending = false
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { shown = i; dx = 0 }
                } else {
                    // Next / Previous buttons, the lock screen, the queue: slide the covers across.
                    withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.9)) { shown = i }
                }
            }
    }

    /// VoiceOver for the strip.
    private var accessible: some View {
        covers
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(!video ? "Album artwork" : VideoStore.shared.isEpisode ? "Episode video" : "Music video")
            .accessibilityValue(video ? (VideoStore.shared.frameUp ? "playing" : "loading") : "")
            .accessibilityHint(video ? "Double-tap for video controls. Swipe left or right to change track." : "Swipe left or right to change track.")
            .accessibilityAddTraits(video ? .isButton : [])
            .accessibilityAction(named: "Full screen") { if video { expand() } }
            .accessibilityAction(named: "Next track") { if player.next != nil { player.skipNext() } }
            .accessibilityAction(named: "Previous track") { if player.previous != nil { player.playIndex(player.queue.currentIndex - 1) } }
            .accessibilityIdentifier(video ? "np-video" : "np-artwork")
    }

    private func expand() {
        chrome = false
        VideoStore.shared.enterFullscreen()
    }

    /// The covers around the current one, keyed by queue index so the one sliding to the centre
    /// keeps its view (and its loaded image) when it becomes current.
    private func strip(width w: CGFloat) -> some View {
        let cur = shown ?? player.queue.currentIndex
        let items = player.queue.items
        let slots: [(index: Int, url: String?)] = items.indices.contains(cur)
            ? (cur - 1...cur + 1).filter { items.indices.contains($0) }.map { ($0, items[$0].thumbnail) }
            : [(cur, fallback)]
        return ZStack {
            ForEach(slots, id: \.index) { slot in
                Group {
                    if video && slot.index == cur {
                        NPVideoFrame(width: w)
                    } else {
                        ArtImage(url: slot.index == cur ? (slot.url ?? fallback) : slot.url, px: 1080, radius: Radius.l)
                    }
                }
                .frame(width: w, height: w)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
                .offset(x: CGFloat(slot.index - cur) * (w + Self.spacing) + dx)
                .accessibilityIdentifier(slot.index == cur ? "np-art-current" : "np-art-\(slot.index < cur ? "previous" : "next")")
            }
        }
        .frame(width: w, height: w)
        .onAppear { width = w; if shown == nil { shown = player.queue.currentIndex } }
        .onChange(of: w) { _, n in width = n }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { v in
                if axis == nil {
                    axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical
                    if axis == .horizontal && chrome { withAnimation(.easeOut(duration: 0.15)) { chrome = false } }
                }
                guard axis == .horizontal, !pending else { return }
                var x = v.translation.width
                // No neighbour that way: rubber-band.
                if x > 0 && player.previous == nil { x = rubber(x) }
                if x < 0 && player.next == nil { x = -rubber(-x) }
                dx = x
            }
            .onEnded { v in
                defer { axis = nil }
                guard axis == .horizontal, !pending else { return }
                switch Self.decide(translation: v.translation.width, predicted: v.predictedEndTranslation.width,
                                   velocity: v.velocity.width, width: width,
                                   hasPrevious: player.previous != nil, hasNext: player.next != nil) {
                case 1: commit(1)
                case -1: commit(-1)
                default: withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { dx = 0 }
                }
            }
    }

    private func rubber(_ x: CGFloat) -> CGFloat { 60 * log10(1 + x / 60) * 1.6 }

    /// Spotify's commit rule: past 30 % of the width, or a flick (fast, or heading well past it).
    /// Returns +1 (next), -1 (previous) or 0 (spring back).
    static func decide(translation x: CGFloat, predicted: CGFloat, velocity: CGFloat, width w: CGFloat,
                       hasPrevious: Bool, hasNext: Bool) -> Int {
        let flick: CGFloat = 500
        let towardsNext = x < -w * 0.3 || (velocity < -flick && x < -12) || (predicted < -w * 0.7 && x < -12)
        let towardsPrevious = x > w * 0.3 || (velocity > flick && x > 12) || (predicted > w * 0.7 && x > 12)
        if towardsNext && hasNext { return 1 }
        if towardsPrevious && hasPrevious { return -1 }
        return 0
    }

    /// Slide the neighbour to the centre, then play it; `onChange(currentIndex)` parks the strip.
    private func commit(_ direction: Int) {
        pending = true
        withAnimation(.easeOut(duration: 0.2)) { dx = direction > 0 ? -(width + Self.spacing) : width + Self.spacing }
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            // Previous is the previous track, not a restart (unlike the ⏮ button after 3 s).
            if direction > 0 { player.skipNext() } else { player.playIndex(player.queue.currentIndex - 1) }
            // The core didn't move (error, end of queue): put the cover back.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if pending { pending = false; withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dx = 0 } }
        }
    }
}

/// Seek bar: 4pt line, white fill, thumb; grows while dragging; elapsed / remaining.
struct Scrubber: View {
    @Environment(AppModel.self) private var app
    var compact = false
    /// 4 pt on Now Playing; 2 pt for the mini scrubber under full-screen lyrics.
    var trackHeight: CGFloat = 4
    /// Between the times, always: the chapter playing (the full-screen video). Otherwise only while
    /// dragging, where it follows the thumb.
    var showsChapter = false
    /// Every drag step (the full-screen overlay stays up while you scrub).
    var onDrag: (() -> Void)? = nil
    @State private var dragValue: Double?
    /// The chapter under the thumb during a drag: crossing into another one ticks.
    @State private var dragChapter: Int?
    /// The finger's recent (x, time) during a drag, for its speed at release, and the detent
    /// ticks' generator, prepared at touch-down so the first tick isn't late. A reference, so
    /// recording a sample doesn't redraw.
    @State private var samples = DragSamples()

    final class DragSamples {
        var list: [(x: Double, t: Double)] = []
        let tick = UISelectionFeedbackGenerator()
        func fire() { tick.selectionChanged(); tick.prepare() }
    }

    /// The playing episode's chapters.
    private var chapters: [PodcastChapter] {
        let p = app.player
        guard let s = p.current, s.isEpisode == true, let list = app.podcasts.chapters[s.videoId] else { return [] }
        return list
    }

    /// Chapter starts as fractions of the length.
    private var marks: [Double] {
        let d = app.player.duration
        guard d > 0 else { return [] }
        return chapters.map { $0.startSecs / d }.filter { $0 > 0 && $0 < 1 }
    }

    /// A drag at `x` of `w`: the thumb follows the finger, softly held for a few points at each
    /// chapter start (`chapterDetent`); a selection tick marks every start it crosses.
    private func drag(to x: CGFloat, of w: CGFloat, at t: Date) {
        samples.list.append((Double(x), t.timeIntervalSinceReferenceDate))
        if samples.list.count > 12 { samples.list.removeFirst(samples.list.count - 12) }
        let d = app.player.duration
        let raw = min(1, max(0, x / max(w, 1)))
        let first = dragValue == nil
        if first { samples.tick.prepare() }
        guard d > 0, !chapters.isEmpty else { setDrag(raw, animated: first); return }
        let secs = chapterDetent(chapters, raw * d, duration: d, width: Double(w))
        let i = chapterAt(chapters, secs)
        if let was = dragChapter, was != i { samples.fire() }
        dragChapter = i
        setDrag(secs / d, animated: first)
    }

    /// The touch-down grows the bar and moves the thumb under the finger in 0.12 s; every later
    /// frame follows the finger as is.
    private func setDrag(_ v: Double, animated: Bool) {
        if animated { withAnimation(.easeOut(duration: 0.12)) { dragValue = v } } else { dragValue = v }
    }

    /// The finger lifts: a slow release a few points from a chapter start settles onto it with a
    /// short spring (`chapterSettle`); anything else lands exactly where released.
    private func release(of w: CGFloat, at t: Date) {
        let p = app.player
        defer { samples.list = [] }
        guard let v = dragValue else { return }
        let d = p.duration
        let speed = releaseSpeed(samples.list, end: t.timeIntervalSinceReferenceDate)
        let secs = chapterSettle(chapters, v * d, duration: d, width: Double(w), speed: speed)
        let settles = secs != v * d
        if settles, chapterAt(chapters, secs) != dragChapter { samples.fire() }
        withAnimation(settles ? .spring(response: 0.25, dampingFraction: 0.8) : .easeOut(duration: 0.12)) {
            if d > 0 { p.seek(secs) }
            dragValue = nil
            dragChapter = nil
        }
    }

    var body: some View {
        let p = app.player
        let value = dragValue ?? p.progress
        let list = chapters
        let ci = chapterAt(list, value * p.duration)
        let middle = (showsChapter || dragValue != nil) && list.indices.contains(ci) ? list[ci].title : nil
        // Track 4 pt white 30 %, white fill, 12 pt thumb visible at rest (16 while dragging); 32 pt hit area.
        let thumb: CGFloat = dragValue == nil ? (trackHeight < 4 ? 8 : 12) : 16
        VStack(spacing: 0) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.3)).frame(height: dragValue == nil ? trackHeight : trackHeight + 2)
                    Capsule().fill(Color.white).frame(width: max(0, w * value), height: dragValue == nil ? trackHeight : trackHeight + 2)
                    // stream: chapters — a thin gap at each chapter start splits the bar.
                    ForEach(marks, id: \.self) { m in
                        Rectangle().fill(Color.black.opacity(0.85)).frame(width: 2, height: trackHeight + 2)
                            .offset(x: w * m - 1)
                    }
                    Circle().fill(Color.white).frame(width: thumb)
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .offset(x: w * value - thumb / 2)
                }
                .frame(height: 32)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in drag(to: v.location.x, of: w, at: v.time); onDrag?() }
                    .onEnded { v in release(of: w, at: v.time) })
            }
            .frame(height: 32)
            .accessibilityElement()
            .accessibilityLabel("Position")
            .accessibilityValue(timecode(value * p.duration))
            .accessibilityIdentifier("np-scrubber")
            if !compact {
                HStack {
                    Text(timecode(value * p.duration))
                    Spacer()
                    if let middle {
                        Text(middle).font(Typo.font(12, .semibold)).foregroundStyle(Palette.text).lineLimit(1)
                            .accessibilityIdentifier("np-scrubber-chapter")
                        Spacer()
                    }
                    Text(timecode(p.duration))
                }
                .font(Typo.time).monospacedDigit().foregroundStyle(Palette.text.opacity(0.7))
                .padding(.top, -8)
            }
        }
    }
}

func timecode(_ s: Double) -> String {
    let t = Int(s.rounded(.down))
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

// MARK: cards under the player

/// stream: chapters. The playing chapter and the next two; "Show all" opens the Chapters sheet.
/// Hidden when the episode has no chapters.
struct ChaptersCard: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let p = app.player
        let list = p.current?.isEpisode == true ? (app.podcasts.chapters[p.current?.videoId ?? ""] ?? []) : []
        if !list.isEmpty {
            let active = chapterAt(list, p.position)
            let start = max(0, min(active, list.count - 3))
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    Text("Chapters").font(Typo.font(16, .bold))
                    Spacer()
                    if list.count > 3 {
                        Button("Show all") { app.sheet = .chapters }
                            .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).frame(height: 32)
                            .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
                            .accessibilityIdentifier("np-chapters-all")
                    }
                }
                ChapterRows(chapters: Array(list[start..<min(list.count, start + 3)]),
                            active: active, offset: start) { p.seek($0.startSecs) }
            }
            .foregroundStyle(Palette.text)
            .padding(Space.l)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.elevatedHighlight))
            .padding(.horizontal, Space.gutter)
            .accessibilityIdentifier("np-chapters")
        }
    }
}

struct NextInQueueCard: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let next = Array(app.player.upcoming.prefix(3))
        if !next.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack {
                    Text("Next in queue").font(Typo.font(16, .bold))
                    Spacer()
                    Button("Open queue") { app.router.queueOpen = true }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 16).frame(height: 32)
                        .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
                }
                ForEach(next, id: \.index) { item in
                    HStack(spacing: Space.m) {
                        ArtImage(url: item.song.thumbnail, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.song.title).font(Typo.rowTitle).lineLimit(1)
                            Text(item.song.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { app.player.playIndex(item.index) }
                    .accessibilityAddTraits(.isButton)
                }
            }
            .foregroundStyle(Palette.text)
            .padding(Space.l)
            .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.elevatedHighlight))
            .padding(.horizontal, Space.gutter)
        }
    }
}

struct AboutArtistCard: View {
    @Environment(AppModel.self) private var app
    let artist: ArtistPage
    /// The label flips on the tap; the library catches up (or a failure toast puts it back).
    @State private var pending: Bool?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ArtImage(url: artist.thumbnail, px: 1080, radius: 0).frame(height: 200).clipped()
                LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .center)
                Text("About the artist").font(Typo.font(16, .bold)).padding(Space.l)
            }
            .frame(height: 200)
            VStack(alignment: .leading, spacing: Space.s) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artist.name ?? "").font(Typo.font(16, .bold))
                        if let m = artist.monthlyListeners { Text(m.replacingOccurrences(of: "audience", with: "listeners")).font(Typo.meta).foregroundStyle(Palette.subdued) }
                    }
                    Spacer()
                    let saved = app.library.isSaved(artist.channelId)
                    let following = pending ?? saved
                    Button(following ? "Following" : "Follow") {
                        guard pending == nil else { return }
                        pending = !saved
                        let on = app.library.toggleSaved(BrowseItem(kind: .artist, id: artist.channelId, title: artist.name ?? "", subtitle: "Artist", thumbnail: artist.thumbnail))
                        Haptics.impact(.light)
                        app.showToast(on ? "Following \(artist.name ?? "artist")" : "Unfollowed \(artist.name ?? "artist")")
                        Task { try? await Task.sleep(nanoseconds: 4_000_000_000); pending = nil }
                    }
                    .onChange(of: saved) { _, _ in pending = nil }
                    .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, 16).frame(height: 32)
                    .overlay(Capsule().stroke(following ? Palette.text : Palette.muted, lineWidth: 1))
                }
                if let d = artist.description {
                    Text(d).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(3)
                }
            }
            .padding(Space.l)
        }
        .foregroundStyle(Palette.text)
        .background(Palette.elevatedHighlight)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
        .padding(.horizontal, Space.gutter)
        .onTapGesture {
            app.router.nowPlayingOpen = false
            app.router.push(.artist(artist.channelId))
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// The cover as ONE element between the mini player and Now Playing: on open it travels from the
/// mini cover to the big one (and back on close) above both, while the two real covers hide. Frames
/// are measured in global space; Now Playing's is kept at rest (its slide offset taken out).
@MainActor @Observable final class ArtFlight {
    static let shared = ArtFlight()
    struct Leg { var from: CGRect; var to: CGRect; var fromRadius: CGFloat; var toRadius: CGFloat; var url: String? }
    private(set) var leg: Leg?
    private(set) var arrived = false
    @ObservationIgnored var mini: CGRect = .zero
    @ObservationIgnored var npArt: CGRect = .zero
    @ObservationIgnored var npSheetY: CGFloat = 0
    @ObservationIgnored var drag: CGFloat = 0
    @ObservationIgnored private var generation = 0
    var flying: Bool { leg != nil }
    private var npRest: CGRect { npArt.offsetBy(dx: 0, dy: -npSheetY) }

    func start(open: Bool, url: String?) {
        generation += 1
        let g = generation
        guard !Motion.reduce, mini.width > 0, npArt.width > 0, url != nil,
              !VideoStore.shared.showsVideo, !VideoStore.shared.miniShowsVideo else { leg = nil; return }
        let np = npRest.offsetBy(dx: 0, dy: max(0, drag))
        leg = open ? Leg(from: mini, to: npRest, fromRadius: Radius.s, toRadius: Radius.l, url: url)
                   : Leg(from: np, to: mini, fromRadius: Radius.l, toRadius: Radius.s, url: url)
        arrived = false
        withAnimation(open ? NowPlayingCover.openAnimation : NowPlayingCover.closeAnimation) {
            arrived = true
        } completion: { [weak self] in
            guard let self, self.generation == g else { return }
            self.leg = nil
        }
    }
}

struct ArtFlightView: View {
    private var flight: ArtFlight { ArtFlight.shared }
    var body: some View {
        GeometryReader { g in
            if let leg = flight.leg {
                let o = g.frame(in: .global).origin
                let r = flight.arrived ? leg.to : leg.from
                ArtImage(url: leg.url, px: 1080, radius: flight.arrived ? leg.toRadius : leg.fromRadius)
                    .frame(width: r.width, height: r.height)
                    .shadow(color: .black.opacity(flight.arrived ? 0.35 : 0), radius: 24, y: 10)
                    .position(x: r.midX - o.x, y: r.midY - o.y)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
