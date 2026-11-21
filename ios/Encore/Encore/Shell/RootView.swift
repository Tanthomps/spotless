// The app shell: one NavigationStack per tab (all kept alive), the bottom chrome (fade, mini player,
// custom tab bar), toasts, bottom-sheet menus, and the Now Playing cover above everything.
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        @Bindable var router = app.router
        ZStack(alignment: .bottom) {
            Palette.base.ignoresSafeArea()
            ForEach([Tab.home, .search, .library], id: \.self) { tab in
                NavigationStack(path: router.binding(tab)) {
                    tabRoot(tab)
                        .navigationDestination(for: Route.self) { destination($0) }
                }
                .opacity(router.tab == tab ? 1 : 0)
                .allowsHitTesting(router.tab == tab)
                .accessibilityHidden(router.tab != tab)
            }
            BottomChrome()
                .background(alignment: .bottom) {
                    // Black fade behind the tab bar and the mini player.
                    LinearGradient(stops: [.init(color: .black.opacity(0), location: 0), .init(color: .black.opacity(0.85), location: 0.38),
                                           .init(color: .black, location: 0.62)], startPoint: .top, endPoint: .bottom)
                        .frame(height: chromeHeight(app) + 110)
                        .offset(y: 34)
                        .allowsHitTesting(false)
                }
            CreateMenuOverlay()
                .zIndex(2.2)
            SideMenu()
                .zIndex(2.5)
            NowPlayingCover()
                .zIndex(3)
            ArtFlightView()
                .zIndex(3.5)
            // Above Now Playing too, so an Undo from its ··· menu is visible (Spotify shows it there).
            if let toast = app.toast, !(app.router.nowPlayingOpen && app.router.queueOpen) {
                ToastView(message: toast)
                    .padding(.bottom, app.router.nowPlayingOpen ? 40 : chromeHeight(app) + 8)
                    .transition(Motion.toast)
                    .zIndex(4)
            }
        }
        .ignoresSafeArea(.keyboard)
        // The play button can't spin forever: past 15 s on one track, give up and say so.
        .task(id: app.player.loading ? app.player.now?.videoId : nil) {
            guard app.player.loading, let id = app.player.now?.videoId else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard !Task.isCancelled, app.player.loading, app.player.now?.videoId == id else { return }
            app.player.now?.loading = false
            app.fail("This is taking too long. Tap play to try again.")
        }
        // A YouTube session that couldn't be renewed: say so once, with the way back in.
        .onChange(of: app.account.sessionExpired) { _, ended in
            guard ended else { return }
            app.showToast("Your YouTube session ended. Sign in again.", action: "Sign in") {
                app.router.dismissOverlays()
                app.router.push(.settingsPage(.account))
                app.account.signInOpen = true
            }
        }
        .onChange(of: app.router.nowPlayingOpen && app.player.hasTrack) { _, open in
            ArtFlight.shared.start(open: open, url: app.player.current?.thumbnail ?? app.player.now?.thumbnail)
        }
        .sheet(item: $app.sheet) { subject in
            sheetContent(subject)
                .modifier(SheetDetents(detents: detents(subject)))
                .presentationDragIndicator(.visible)
                // Spotify 9.1.90: floating dark Liquid Glass sheets, inset 8 pt, radius ~36.
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .sheet(isPresented: Bindable(app.jam!).sheetOpen) {
            JamSheet().environment(app)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .fullScreenCover(isPresented: $app.importOpen, onDismiss: { app.devices.importClosed() }) { ImportOnboarding().environment(app) }
        // Device sync: link a Mac (Screens/Devices.swift), and the first-run offer after the import.
        .sheet(isPresented: Bindable(app.devices).sheetOpen, onDismiss: { app.devices.closed() }) {
            LinkDeviceSheet().environment(app)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .fullScreenCover(isPresented: Bindable(app.devices).welcomeOpen) { DeviceLinkWelcome().environment(app) }
        #if DEBUG
        .sheet(isPresented: Bindable(app.router).debugOpen) { DebugAudioMenu() }
        #endif
        .alert(app.confirm?.title ?? "", isPresented: Binding(get: { app.confirm != nil }, set: { if !$0 { app.confirm = nil } }),
               presenting: app.confirm) { c in
            Button("Cancel", role: .cancel) {}
            Button(c.action, role: c.destructive ? .destructive : nil) { c.run() }
        } message: { c in
            if let m = c.message { Text(m) }
        }
        .preferredColorScheme(.dark)
        // Like Spotify, the app's type is fixed-size (Typo uses fixedSize fonts); system text inside
        // it stops growing at xxxLarge so rows and sheets keep their layout.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    @ViewBuilder private func sheetContent(_ s: SheetSubject) -> some View {
        switch s {
        case .sleepTimer: SleepTimerSheet()
        case .speed: SpeedSheet()
        case .chapters: ChaptersSheet()
        case .effects: EffectsSheet()
        case .aboutRecommendations: AboutRecommendationsSheet()
        case .newFolder: NameSheet(kind: .folder)
        case .newPlaylist: NameSheet(kind: .playlist)
        case .newCollab: NameSheet(kind: .collab)
        case .editPlaylist(let id): EditPlaylistSheet(id: id)
        case .addSongs(let id, let name): AddSongsSheet(id: id, name: name)
        case .create, .sort: FittedActionSheet(subject: s)
        case .addToPlaylist(let songs): AddToPlaylistSheet(songs: songs)
        default: ActionSheet(subject: s)
        }
    }

    /// nil: the sheet sets its own (content-fitted) detent.
    private func detents(_ s: SheetSubject) -> Set<PresentationDetent>? {
        switch s {
        case .create, .sort: nil
        case .sleepTimer: [.height(470)]
        case .speed: [.height(420)]
        case .effects: [.large]
        case .aboutRecommendations: [.large]
        case .newFolder, .newPlaylist, .newCollab, .addToPlaylist, .editPlaylist, .addSongs: [.large]
        default: [.medium, .large]
        }
    }

    @ViewBuilder private func tabRoot(_ tab: Tab) -> some View {
        switch tab {
        case .home: HomeView()
        case .search: SearchView()
        case .library: LibraryView()
        case .create: EmptyView()
        }
    }

    @ViewBuilder private func destination(_ r: Route) -> some View {
        switch r {
        case .album(let id): AlbumView(id: id)
        case .artist(let id): ArtistView(id: id)
        case .playlist(let id): PlaylistView(id: id)
        case .dailyMix(let id, let title, let subtitle, let art): DailyMixView(id: id, title: title, subtitle: subtitle, art: art)
        case .liked: PlaylistView(id: likedPlaylistId)
        case .searchResults(let q): SearchResultsView(query: q)
        case .mood(let params, let title): MoodView(params: params, title: title)
        // stream: audiobooks — a chapter's "show" is its book.
        case .show(let id): if let b = audiobookId(fromShow: id) { AudiobookView(id: b) } else { ShowView(id: id) }
        case .audiobook(let id): AudiobookView(id: id)
        case .episode(let id): EpisodeView(id: id)
        case .yourEpisodes: EpisodeListView(kind: .saved)
        case .newEpisodes: EpisodeListView(kind: .new)
        case .madeForYou: MadeForYouView()
        case .whatsNew: WhatsNewView()
        case .charts: ChartsView()
        case .newReleases: NewReleasesView()
        case .folder(let id): FolderView(id: id)
        case .settings: SettingsView()
        case .settingsPage(let p): SettingsPageView(page: p)
        // #27 "Show all" on Home shelves.
        case .shelf(let id, let title): ShelfGridView(id: id, title: title)
        case .radio(let kind, let id, let name): RadioView(kind: kind, id: id, name: name)
        case .history: HistoryView()
        case .stats: StatsView()
        }
    }
}

/// Dark glass behind sheets: the page blurs through, tinted near #1f1f1f so rows stay legible.
/// Spotify's sheets are frosted glass, not grey: what's behind shows faintly through the blur, and
/// the edge carries a lit hairline that fades down the sides. Every floating sheet uses this.
struct SheetGlass: View {
    var radius: CGFloat = Radius.glassSheet
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Color(hex: "#161616").opacity(0.55)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06), .clear],
                                             startPoint: .top, endPoint: .center), lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct SheetDetents: ViewModifier {
    let detents: Set<PresentationDetent>?
    func body(content: Content) -> some View {
        if let detents { content.presentationDetents(detents) } else { content }
    }
}

/// Bottom space screens reserve so content scrolls clear of the mini player, the offline bar and
/// the tab bar.
@MainActor func chromeHeight(_ app: AppModel) -> CGFloat {
    Metrics.tabBarHeight + (app.player.hasTrack ? Metrics.miniPlayerHeight + Metrics.miniGap : 0)
        + (app.downloads.offline ? OfflineBanner.height + Metrics.miniGap : 0)
}

struct ChromeInset: ViewModifier {
    @Environment(AppModel.self) private var app
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) { Color.clear.frame(height: chromeHeight(app) + 16) }
    }
}

extension View {
    func chromeInset() -> some View { modifier(ChromeInset()) }
}

struct BottomChrome: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        VStack(spacing: Metrics.miniGap) {
            if app.downloads.offline {
                OfflineBanner(offlineMode: app.downloads.snapshot.network.offlineMode)
                    .padding(.horizontal, Metrics.miniPlayerInset)
                    .transition(Motion.slide(.bottom, fade: true))
            }
            if app.jam.active {
                JamPill().transition(Motion.slide(.bottom, fade: true))
            }
            // Another linked device is playing and this one isn't: Spotify's "Playing on <device>" bar.
            if let r = app.devices.activeRemote, r.playing, !app.player.hasTrack || app.player.paused {
                RemoteDeviceBar(device: r)
                    .padding(.horizontal, Metrics.miniPlayerInset)
                    .transition(Motion.slide(.bottom, fade: true))
            }
            if app.player.hasTrack {
                MiniPlayer().padding(.horizontal, Metrics.miniPlayerInset)
                    .transition(Motion.slide(.bottom, fade: true))
            }
            TabBar()
        }
        .animation(Motion.spring, value: app.player.hasTrack)
        .animation(Motion.spring, value: app.devices.activeRemote?.playing)
        .animation(Motion.spring, value: app.jam.active)
        .animation(Motion.spring, value: app.downloads.offline)
        .onChange(of: app.downloads.offline) { was, now in
            guard was != now else { return }
            // VoiceOver hears the flip either way; the bar itself is the sighted cue.
            UIAccessibility.post(notification: .announcement,
                                 argument: now ? OfflineBanner.text(offlineMode: app.downloads.snapshot.network.offlineMode) : "Back online")
        }
    }
}

/// A linked device playing: its song and name in accent, play/pause and next sent to it. Tapping
/// opens the controls with "Play here" (take the song over at its position).
struct RemoteDeviceBar: View {
    @Environment(AppModel.self) private var app
    let device: RemoteDevice
    @State private var open = false
    var body: some View {
        HStack(spacing: Space.m) {
            ArtImage(url: device.song?.thumbnail, px: 120, radius: Radius.xs).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.song?.title ?? "").font(Typo.font(13, .bold)).lineLimit(1)
                HStack(spacing: 4) {
                    Icon(name: "devices", size: 12)
                    Text(app.devices.sending.contains(device.dev) ? "Sending to \(device.name)…" : "Playing on \(device.name)")
                        .font(Typo.font(12, .medium)).lineLimit(1)
                        .contentTransition(.opacity)
                }
                .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
            Button { app.devices.control(device, device.playing ? "pause" : "play") } label: {
                IconSwap(name: device.playing ? "pause" : "play", fill: true, size: 22).frame(width: 40, height: 40)
            }
            .accessibilityLabel(device.playing ? "Pause on \(device.name)" : "Play on \(device.name)")
            Button { app.devices.control(device, "next") } label: {
                SkipGlyph(forward: true, size: 24).frame(width: 36, height: 40)
            }
            .accessibilityLabel("Next on \(device.name)")
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.s).frame(height: 48)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color(hex: "#0f3a22")))
        .contentShape(Rectangle())
        .onTapGesture { open = true }
        .accessibilityIdentifier("remote-device-bar")
        .sheet(isPresented: $open) {
            RemoteDeviceSheet(device: device).environment(app)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
    }
}

/// The other device's controls, and "Play here": this phone picks the song up where it is.
struct RemoteDeviceSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let device: RemoteDevice
    var body: some View {
        let live = app.devices.remotes.first { $0.dev == device.dev } ?? device
        VStack(spacing: Space.l) {
            HStack(spacing: Space.m) {
                ArtImage(url: live.song?.thumbnail, px: 200, radius: Radius.s).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(live.song?.title ?? "").font(Typo.font(16, .bold)).lineLimit(1)
                    Text(live.song?.artists ?? "").font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(1)
                    Text(app.devices.sending.contains(live.dev) ? "Sending to \(live.name)…" : "Playing on \(live.name)")
                        .font(Typo.font(13, .semibold)).foregroundStyle(Palette.accent).lineLimit(1)
                }
                Spacer()
            }
            HStack(spacing: Space.xxl) {
                Button { app.devices.control(live, "prev") } label: { SkipGlyph(forward: false, size: 32) }
                    .accessibilityLabel("Previous")
                PlayCircleButton(playing: live.playing, size: 56, color: .white) { app.devices.control(live, live.playing ? "pause" : "play") }
                Button { app.devices.control(live, "next") } label: { SkipGlyph(forward: true, size: 32) }
                    .accessibilityLabel("Next")
            }
            .foregroundStyle(Palette.text)
            Button {
                playHere(live)
            } label: {
                Text("Play on this iPhone").font(Typo.font(15, .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).frame(height: 48)
                    .background(Capsule().fill(Palette.accent))
            }
            .buttonStyle(PressScale())
            .accessibilityIdentifier("remote-play-here")
        }
        .padding(Space.xl)
        .foregroundStyle(Palette.text)
    }

    /// Take over: the same song here, at the other device's position now, and pause it there.
    private func playHere(_ d: RemoteDevice) {
        guard let s = d.song else { return }
        let elapsed = d.playing ? max(0, Date().timeIntervalSince1970 * 1000 - (d.at ?? 0)) : 0
        let pos = ((d.posMs ?? 0) + elapsed) / 1000
        let song = SongItem(videoId: s.videoId, title: s.title, artists: s.artists, thumbnail: s.thumbnail)
        app.player.play([song], at: 0, context: PlayContext(kind: .song, id: s.videoId, title: s.title), startSecs: pos)
        app.devices.control(d, "pause")
        dismiss()
    }
}

/// Spotify's offline cue: a slim dark bar above the mini player for as long as there's no
/// connection (or Offline mode is on). Only downloads play meanwhile; rows that can't are greyed.
struct OfflineBanner: View {
    static let height: CGFloat = 32
    let offlineMode: Bool

    static func text(offlineMode: Bool) -> String { offlineMode ? "Offline mode is on" : "No internet connection" }

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold))
            Text(Self.text(offlineMode: offlineMode)).font(Typo.font(13, .bold)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.m)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color(hex: "#2a2a2a")))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("offline-banner")
    }
}

struct TabBar: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let selected = app.router.tab == tab && tab != .create
                Button {
                    if tab == .create { app.router.createOpen.toggle() } else { app.router.createOpen = false; app.router.select(tab) }
                } label: {
                    VStack(spacing: 3) {
                        Group {
                            switch tab {
                            case .home: Icon(name: "house", fill: selected, size: Metrics.tabIcon)
                            case .search: SearchGlyph(bold: selected, size: Metrics.tabIcon)
                            case .library: LibraryGlyph(filled: selected, size: Metrics.tabIcon)
                            case .create:
                                // Open: Spotify turns the tab into a white circle with a black ✕.
                                if app.router.createOpen {
                                    Icon(name: "x", size: 20).foregroundStyle(.black)
                                        .frame(width: 40, height: 40).background(Circle().fill(.white))
                                        .frame(width: Metrics.tabIcon, height: Metrics.tabIcon)
                                        .transition(.scale.combined(with: .opacity))
                                } else {
                                    Icon(name: "plus", size: Metrics.tabIcon)
                                }
                            }
                        }
                        Text(tab.title).font(Typo.font(11, selected ? .semibold : .medium)).lineLimit(1)
                    }
                    .foregroundStyle(selected ? Palette.text : Palette.subdued)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressScale(scale: 0.92))
                .accessibilityIdentifier("tab-\(tab.rawValue)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: Metrics.tabBarHeight)
        .padding(.top, 2)
    }
}

struct ToastView: View {
    @Environment(AppModel.self) private var app
    let message: ToastMessage
    var body: some View {
        HStack(spacing: Space.m) {
            // White toast, black 14/400 text; the action ("Change") 14/700 black at the right (Spotify).
            Text(message.text).font(Typo.font(14)).foregroundStyle(.black).lineLimit(3)
            Spacer(minLength: 0)
            if let action = message.action {
                Text(action).font(Typo.font(14, .bold)).foregroundStyle(.black)
            }
        }
        .padding(.horizontal, Space.l)
        .frame(minHeight: 48)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Color.white))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.horizontal, Space.s)
        .onTapGesture {
            let run = message.run
            withAnimation(Motion.exit) { app.toast = nil }
            run?()
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(message.run != nil ? .isButton : [])
        .accessibilityIdentifier("toast")
    }
}
