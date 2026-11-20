// Shared building blocks: icons, chips, buttons, track rows (swipe right → queue), cards, badges,
// the row swipe, greyed-row reasons and the title marquee.
import SwiftUI

/// Phosphor glyph from the asset catalog (`ph-<name>` / `ph-<name>-fill`).
struct Icon: View {
    let name: String
    var fill = false
    var size: CGFloat = 24
    var body: some View {
        if name.isEmpty {
            Color.clear.frame(width: size, height: size)
        } else {
            Image("ph-\(name)\(fill ? "-fill" : "")").renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size)
        }
    }
}

/// An `Icon` whose swaps blend: the old glyph shrinks to 0.8 and blurs out while the new one does
/// the reverse, overlapping. (`.contentTransition(.symbolEffect)` does nothing on asset images.)
struct IconSwap: View {
    let name: String
    var fill = false
    var size: CGFloat = 24
    var body: some View {
        ZStack {
            Icon(name: name, fill: fill, size: size)
                .id("\(name)\(fill)")
                .transition(Motion.reduce ? .opacity : .modifier(active: PopEffect(scale: 0.8, blur: 4, opacity: 0), identity: PopEffect(scale: 1, blur: 0, opacity: 1)))
        }
        .animation(.easeOut(duration: 0.18), value: "\(name)\(fill)")
    }
}

/// Grey placeholder rows while a list loads (skeletons, never a spinner).
struct SkeletonRows: View {
    var count = 6
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                HStack(spacing: Space.m) {
                    RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.elevatedHighlight).frame(width: Metrics.rowArt, height: Metrics.rowArt)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Palette.elevatedHighlight).frame(width: 160, height: 10)
                        Capsule().fill(Palette.elevatedHighlight).frame(width: 100, height: 8)
                    }
                    Spacer()
                }
                .padding(.horizontal, Space.gutter).frame(height: Metrics.rowHeight)
                .opacity(1 - Double(i) * 0.1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}

/// End of a paged list whose next page failed: says so and retries in place.
struct LoadMoreFailedRow: View {
    var text = "Couldn't load more"
    let retry: () -> Void
    var body: some View {
        HStack {
            Text(text).font(Typo.font(14)).foregroundStyle(Palette.subdued)
            Spacer()
            Button("Try again", action: retry).font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, Space.gutter).frame(height: 56)
        .accessibilityIdentifier("load-more-failed")
    }
}

/// Our own library glyph (three spines and a leaning one); Phosphor has no close match.
struct LibraryGlyph: View {
    var filled = false
    var size: CGFloat = 24
    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24
            let w: CGFloat = filled ? 2.6 : 2
            for x in [4.0, 9.0] {
                ctx.fill(Path(roundedRect: CGRect(x: x * s, y: 3 * s, width: w * s, height: 18 * s), cornerRadius: 1 * s), with: .foreground)
            }
            var lean = Path(roundedRect: CGRect(x: 0, y: 0, width: w * s, height: 18.5 * s), cornerRadius: 1 * s)
            lean = lean.applying(CGAffineTransform(rotationAngle: -.pi / 9).concatenating(CGAffineTransform(translationX: 13.5 * s, y: 3.6 * s)))
            ctx.fill(lean, with: .foreground)
        }
        .frame(width: size, height: size)
    }
}

struct Chip: View {
    let title: String
    var selected = false
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(title).font(Typo.chip)
                .foregroundStyle(selected ? Color.black : Palette.text)
                .padding(.horizontal, 16).frame(height: Metrics.chipHeight)
                .background(Capsule().fill(selected ? Palette.accent : Color(hex: "#2a2a2a")))
        }
        .buttonStyle(PressScale())
    }
}

/// Press feedback by scale alone (play buttons keep their colour).
struct ScaleOnly: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.96
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1).opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The big accent circular play/pause button.
struct PlayCircleButton: View {
    var playing: Bool
    var size: CGFloat = Metrics.playButton
    var color: Color = Palette.accent
    /// stream: instant: the track is picked and its audio is on the way.
    var loading = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: size, height: size)
                .overlay {
                    if loading {
                        ProgressView().tint(.black)
                    } else {
                        IconSwap(name: playing ? "pause" : "play", fill: true, size: size * 0.42).foregroundStyle(.black)
                            .offset(x: playing ? 0 : size * 0.03)
                    }
                }
        }
        // Spotify: press scales to 0.96, no colour change.
        .buttonStyle(ScaleOnly(scale: 0.96))
        .accessibilityLabel(loading ? "Loading" : playing ? "Pause" : "Play")
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E").font(Typo.font(10, .bold)).foregroundStyle(.black)
            .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: 2).fill(Palette.subdued))
    }
}

/// Animated 4-bar equaliser for the playing row.
struct EqualizerGlyph: View {
    var animating: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 12, paused: !animating)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<4) { i in
                    let h = animating ? 0.3 + 0.7 * abs(sin(t * (3.1 + Double(i) * 1.3) + Double(i))) : [0.4, 0.8, 0.55, 0.3][i]
                    RoundedRectangle(cornerRadius: 0.5).fill(Palette.accent).frame(width: 2.2, height: 12 * h)
                }
            }
            .frame(width: 14, height: 12, alignment: .bottom)
        }
    }
}

/// Track row: 48pt art, title (accent when playing), E badge, download arrow, artist, `…`.
/// Swipe right past the threshold adds it to the queue; swipe left likes/unlikes (`rowSwipe`).
/// Rows playback steps over (offline, hidden, explicit filter) are greyed, and a tap says why.
struct TrackRow: View {
    @Environment(AppModel.self) private var app
    let song: SongItem
    var index: Int? = nil
    var showArt = true
    /// Artist "Popular" rows: the play count replaces the artist line, as in Spotify.
    var showPlays = false
    var context: PlayContext?
    var onTap: () -> Void

    var isCurrent: Bool { app.player.now?.videoId == song.videoId }
    var liked: Bool { app.library.isLiked(song.videoId) }
    /// Why playback steps over this row (nil: it plays).
    var block: RowBlock? { app.rowBlock(song) }

    var body: some View {
        // Settings › Show unplayable songs off: rows playback steps over aren't listed at all.
        if block != nil && app.hidesUnplayable { EmptyView() } else { row }
    }

    private var row: some View {
        content
            .rowSwipe(liked: liked, queue: { app.queue([song], from: context?.title) }, like: { app.toggleLike(song) })
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
            .onTapGesture { if let block { app.explain(block, song) } else { onTap() } }
            .accessibilityAddTraits(.isButton)
            .onLongPressGesture(minimumDuration: 0.4) {
                Haptics.impact(.medium)
                app.sheet = .track(song, context: context)
            } onPressingChanged: { down in
                // stream: firstaudio — the finger is down: start resolving before the tap lands.
                if down && block == nil { app.core.hintPlay(song) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("track-row")
            .accessibilityValue(block != nil ? "unavailable" : "")
            .accessibilityAction(named: "Add to queue") { app.queue([song], from: context?.title) }
            .accessibilityAction(named: "More options") { app.sheet = .track(song, context: context) }
            .accessibilityAction(named: liked ? "Remove from Liked Songs" : "Add to Liked Songs") { app.toggleLike(song) }
    }

    private var content: some View {
        HStack(spacing: Space.m) {
            if let index {
                Group {
                    if isCurrent { EqualizerGlyph(animating: !app.player.paused) } else {
                        Text("\(index)").font(Typo.font(16)).foregroundStyle(Palette.subdued)
                    }
                }.frame(width: 24)
            }
            if showArt { ArtImage(url: song.thumbnail, px: 144, radius: Radius.xs, fallback: ArtRef(id: song.videoId, title: song.title)).frame(width: Metrics.rowArt, height: Metrics.rowArt) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    // The playing row: equaliser before the title (rows with a number show it there instead).
                    if isCurrent && index == nil { EqualizerGlyph(animating: !app.player.paused) }
                    Text(song.title).font(Typo.rowTitle).foregroundStyle(isCurrent ? Palette.accentText : Palette.text).lineLimit(1)
                }
                // Spotify's subtitle prefixes, in order: E badge, accent downloaded arrow, artists.
                HStack(spacing: 5) {
                    if song.explicit == true { ExplicitBadge() }
                    RowDownloadGlyph(videoId: song.videoId)
                    Text(showPlays ? (song.playCount ?? song.artists) : song.artists)
                        .font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Saved songs carry the accent check at the trailing edge, before `…` (not in Liked Songs itself).
            if liked && context?.kind != .liked {
                Icon(name: "check-circle", fill: true, size: 20).foregroundStyle(Palette.accent)
                    .padding(.trailing, -6)
                    .accessibilityLabel("Saved in Liked Songs")
            }
            Button { app.sheet = .track(song, context: context) } label: {
                Icon(name: "dots-three", size: 20).foregroundStyle(Palette.subdued).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options for \(song.title)")
        }
        .padding(.leading, Space.gutter)
        .padding(.trailing, Space.gutter - 12)
        .frame(height: Metrics.rowHeight)
        .opacity(block != nil ? 0.4 : 1)
    }
}

// MARK: row swipe (gap 23)

extension View {
    /// Spotify's song-row swipes: right past about a third of the row adds to the queue, left
    /// saves to / removes from Liked Songs. The row follows the finger over an accent strip with the
    /// action glyph, which pops once armed (light haptic at the threshold, the action on release).
    /// `enabled: false` leaves the view untouched (non-song rows).
    func rowSwipe(enabled: Bool = true, liked: Bool, background: Color = Palette.base,
                  queue: @escaping () -> Void, like: @escaping () -> Void) -> some View {
        modifier(RowSwipe(enabled: enabled, liked: liked, background: background, queue: queue, like: like))
    }
}

struct RowSwipe: ViewModifier {
    var enabled = true
    var liked: Bool
    var background: Color = Palette.base
    var queue: () -> Void
    var like: () -> Void
    @State private var dx: CGFloat = 0
    @State private var armed = false
    @State private var axis: Axis?
    @State private var rowWidth: CGFloat = 402
    /// Commit point: a bit over a third of the row, as in Spotify.
    private var threshold: CGFloat { Self.threshold(width: rowWidth) }
    /// 0 at rest, 1 at the threshold: the glyph grows with it.
    private var progress: CGFloat { min(1, abs(dx) / threshold) }

    static func threshold(width: CGFloat) -> CGFloat { max(96, width * 0.375) }
    /// Past the threshold the row moves at 30 % of the finger (rubber band).
    static func damped(_ x: CGFloat, threshold: CGFloat) -> CGFloat {
        let m = abs(x)
        let d = m < threshold ? m : threshold + (m - threshold) * 0.3
        return x >= 0 ? d : -d
    }

    func body(content: Content) -> some View {
        if enabled {
            let row = ZStack {
                // Revealed under the row while swiping: queue on the left, like on the right. The
                // strip fills in with the accent and the glyph grows as the drag nears the commit point.
                let glyph = Icon(name: dx > 0 ? "queue" : liked ? "check-circle" : "plus-circle",
                                 fill: dx <= 0 && liked, size: 24)
                    .scaleEffect(armed ? 1.15 : 0.6 + 0.4 * progress)
                    .animation(.spring(response: 0.25, dampingFraction: 0.6), value: armed)
                HStack {
                    if dx > 0 { glyph.padding(.leading, 24); Spacer() } else { Spacer(); glyph.padding(.trailing, 24) }
                }
                .foregroundStyle(armed ? Color.black : Palette.text)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(armed ? Palette.accent : Palette.accent.opacity(0.25 + 0.35 * progress))
                .opacity(abs(dx) > 4 ? 1 : 0)
                .accessibilityHidden(true)

                content
                    .background(background.opacity(dx != 0 ? 1 : 0.001))
                    .offset(x: dx)
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
            if #available(iOS 18.0, *) {
                // A UIKit pan that only begins on a sideways drag: vertical drags fail it at once and
                // go to the scroll view; a SwiftUI DragGesture lost real finger swipes to the scroll view.
                row.gesture(RowPan(changed: changed, ended: ended))
            } else {
                row.simultaneousGesture(swipe)
            }
        } else {
            content
        }
    }

    private func changed(_ tx: CGFloat) {
        dx = Self.damped(tx, threshold: threshold)
        let now = abs(tx) >= threshold
        if now != armed { armed = now; Haptics.impact(.light) }
    }

    /// Release: past the threshold runs the action, otherwise (or cancelled) it just springs back.
    private func ended(cancelled: Bool) {
        if armed && !cancelled {
            if dx > 0 { queue() } else { like() }
        }
        armed = false
        withAnimation(Motion.spring) { dx = 0 }
    }

    /// iOS 17 fallback.
    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if axis == nil { axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical }
                guard axis == .horizontal else { return }
                changed(v.translation.width)
            }
            .onEnded { _ in
                ended(cancelled: axis != .horizontal)
                axis = nil
            }
    }
}

/// The row swipe's pan: begins only when the drag is mostly sideways (and not from the screen's
/// left edge, which goes back), and the scroll view's own pan waits for it to fail.
@available(iOS 18.0, *)
struct RowPan: UIGestureRecognizerRepresentable {
    var changed: (CGFloat) -> Void
    var ended: (_ cancelled: Bool) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .began, .changed: changed(g.translation(in: g.view).x)
        case .ended: ended(false)
        case .cancelled, .failed: ended(true)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return true }
            if let w = p.view?.window, p.location(in: w).x < 24 { return false }
            let v = p.velocity(in: p.view), t = p.translation(in: p.view)
            let x = abs(v.x) + abs(v.y) > 1 ? v : CGPoint(x: t.x, y: t.y)
            return abs(x.x) > abs(x.y) * 1.2
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView && other is UIPanGestureRecognizer
        }
    }
}

// MARK: greyed rows say why (gap 29)

/// Why playback steps over a song row. Tapping a greyed row toasts the reason, with a way out
/// where there is one (Unhide, or the Settings page that holds the switch).
enum RowBlock: Equatable {
    case unavailable, offline, offlineMode, hidden, explicit

    /// The core's order (`polish/explicit.rs`): unavailable, then offline, hidden, explicit; then
    /// whatever the queue's `skipReasons` adds.
    static func resolve(unavailable: Bool, offline: Bool, offlineMode: Bool, hidden: Bool,
                        explicitFilter: Bool, explicit: Bool, skipReason: String?) -> RowBlock? {
        if unavailable { return .unavailable }
        if offline { return offlineMode ? .offlineMode : .offline }
        if hidden { return .hidden }
        if explicitFilter && explicit { return .explicit }
        switch skipReason {
        case nil: return nil
        case "explicit": return .explicit
        case "hidden": return .hidden
        case "offline": return offlineMode ? .offlineMode : .offline
        default: return .unavailable
        }
    }

    var message: String {
        switch self {
        case .unavailable: "This song isn't available right now"
        case .offline: "You're offline. Only downloaded songs play."
        case .offlineMode: "Offline mode is on. Only downloaded songs play."
        case .hidden: "You hid this song"
        case .explicit: "Explicit content is turned off"
        }
    }

    /// The toast's action, if any.
    var action: String? {
        switch self {
        case .unavailable, .offline: nil
        case .hidden: "Unhide"
        case .offlineMode, .explicit: "Settings"
        }
    }

    /// The Settings page an action opens.
    var settingsPage: SettingsPage? {
        switch self {
        case .offlineMode: .dataSaver
        case .explicit: .contentDisplay
        default: nil
        }
    }
}

extension AppModel {
    /// Why `song` is greyed here, or nil when it plays.
    func rowBlock(_ song: SongItem) -> RowBlock? {
        RowBlock.resolve(unavailable: song.unavailable == true,
                         offline: downloads.unavailableOffline(song.videoId),
                         offlineMode: downloads.snapshot.network.offlineMode,
                         hidden: library.isHidden(song.videoId),
                         explicitFilter: settings.smart.explicitFilter, explicit: song.explicit == true,
                         skipReason: player.queue.skipReasons?[song.videoId])
    }

    /// A tap on a greyed row: say why (Spotify never leaves it silent), with Unhide or Settings.
    func explain(_ block: RowBlock, _ song: SongItem) {
        Haptics.error()
        switch block {
        case .hidden:
            showToast(block.message, action: block.action) { [weak self] in
                guard let self else { return }
                Task {
                    try? await self.core.setHidden(song, hidden: false)
                    await self.library.refresh()
                    await self.player.refresh()
                    self.showToast("Song unhidden")
                }
            }
        case .offlineMode, .explicit:
            let page = block.settingsPage
            showToast(block.message, action: block.action) { [weak self] in
                guard let self, let page else { return }
                self.router.dismissOverlays()
                self.router.push(.settings)
                self.router.push(.settingsPage(page))
            }
        case .unavailable, .offline:
            showToast(block.message)
        }
    }
}

/// Shelf card: square cover (circle for artists), 1-2 line title, subtitle.
struct MediaCard: View {
    let title: String
    var subtitle: String?
    var thumbnail: String?
    var circle = false
    var size: CGFloat = Metrics.card
    var liked = false
    var fallback: ArtRef? = nil
    var body: some View {
        VStack(alignment: circle ? .center : .leading, spacing: Space.s) {
            if liked { LikedCover(size: size) } else {
                ArtImage(url: thumbnail, px: 360, radius: Radius.s, circle: circle, fallback: fallback).frame(width: size, height: size)
            }
            VStack(alignment: circle ? .center : .leading, spacing: 2) {
                Text(title).font(Typo.cardTitle).foregroundStyle(Palette.text).lineLimit(circle ? 1 : 2)
                    .multilineTextAlignment(circle ? .center : .leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(Typo.cardSubtitle).foregroundStyle(Palette.subdued).lineLimit(circle ? 1 : 2)
                        .multilineTextAlignment(circle ? .center : .leading)
                }
            }
            .frame(width: size, alignment: circle ? .center : .leading)
        }
        .frame(width: size)
    }
}

struct SectionTitle: View {
    let title: String
    var showAll = false
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typo.sectionTitle).foregroundStyle(Palette.text).lineLimit(1)
            Spacer()
            if showAll { Text("Show all").font(Typo.metaBold).foregroundStyle(Palette.subdued) }
        }
        .padding(.horizontal, Space.gutter)
    }
}

/// Liked Songs' generated cover (gradient + heart).
struct LikedCover: View {
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Palette.likedCover)
            .frame(width: size, height: size)
            .overlay(Icon(name: "heart", fill: true, size: size * 0.4).foregroundStyle(.white))
    }
}

/// Initial-in-a-circle avatar (no account: the local user's initial).
/// Tapping it opens the side menu (What's new, Settings and privacy), as in Spotify.
struct Avatar: View {
    @Environment(AppModel.self) private var app
    var size: CGFloat = 32
    var opensMenu = true
    var body: some View {
        Circle().fill(Color(hex: "#f573a0")).frame(width: size, height: size)
            .overlay(Text(String(app.localUser.prefix(1)).uppercased()).font(Typo.font(size * 0.45, .bold)).foregroundStyle(.black))
            .overlay {
                if let photo = ProfilePhoto.shared.image {
                    Image(uiImage: photo).resizable().scaledToFill().frame(width: size, height: size).clipShape(Circle())
                }
            }
            .overlay(alignment: .topTrailing) {
                if opensMenu && app.settings.whatsNewCount > 0 {
                    Circle().fill(Palette.announcement).frame(width: size * 0.3, height: size * 0.3)
                        .overlay(Circle().stroke(Palette.base, lineWidth: 2)).offset(x: 1, y: -1)
                }
            }
            .contentShape(Circle())
            .onTapGesture {
                guard opensMenu else { return }
                Haptics.impact(.light)
                withAnimation(Motion.spring) { app.router.sideMenuOpen = true }
            }
            .accessibilityLabel("Profile")
            .accessibilityAddTraits(opensMenu ? .isButton : [])
            .accessibilityIdentifier(opensMenu ? "avatar" : "avatar-static")
    }
}

/// Header "kind" line under an entity title ("Album • 2013").
func kindLabel(_ k: BrowseKind) -> String {
    switch k { case .album: "Album"; case .artist: "Artist"; case .playlist: "Playlist"; case .song: "Song"; case .podcast: "Podcast"; case .episode: "Episode"; case .audiobook: "Audiobook" }
}

// MARK: marquee (gap 30)

/// A one-line title that scrolls when it doesn't fit (Spotify: mini player and Now Playing). It
/// rests ~2 s at the start, glides left at ~30 pt/s until a second copy, a gap behind, takes the
/// first one's place, then rests again; the edges fade while it overflows. Short titles are plain
/// left-aligned text. Reduce Motion: it truncates instead. With UIKit animations off (snapshot
/// tests) it stays at rest.
struct Marquee: View {
    let text: String
    let font: Font
    var color: Color = Palette.text
    /// Stops (and rewinds) the scroll, e.g. while the carousel is being dragged.
    var paused = false
    var gap: CGFloat = 48
    var speed: CGFloat = 30
    var delay: Double = 2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private var animates: Bool { Self.scrolls(text: textWidth, box: boxWidth, reduceMotion: reduceMotion) }

    /// The title is wider than its box (half a point of slack for rounding).
    static func overflows(text: CGFloat, box: CGFloat) -> Bool { box > 0 && text > box + 0.5 }
    /// It scrolls only when it overflows and Reduce Motion is off (then it truncates).
    static func scrolls(text: CGFloat, box: CGFloat, reduceMotion: Bool) -> Bool { overflows(text: text, box: box) && !reduceMotion }
    /// One glide: the title plus the gap, at `speed` pt/s.
    static func glide(text: CGFloat, gap: CGFloat = 48, speed: CGFloat = 30) -> Double { Double((text + gap) / speed) }

    var body: some View {
        // The hidden copy gives the line its height and takes the offered width.
        Text(text).font(font).lineLimit(1).hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { g in
                Color.clear.onAppear { boxWidth = g.size.width }.onChange(of: g.size.width) { _, w in boxWidth = w }
            })
            .overlay(alignment: .leading) {
                if animates {
                    HStack(spacing: gap) { label; label }
                        .offset(x: offset)
                        .frame(width: boxWidth, alignment: .leading)
                        .clipped()
                        .mask(edgeFade)
                } else {
                    Text(text).font(font).foregroundStyle(color).lineLimit(1)
                }
            }
            .background(alignment: .leading) {
                // Natural width of the full title (never drawn).
                label.hidden().background(GeometryReader { g in
                    Color.clear.onAppear { textWidth = g.size.width }.onChange(of: g.size.width) { _, w in textWidth = w }
                })
            }
            .task(id: Cycle(text: text, run: animates && !paused, distance: textWidth + gap)) { await cycle() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }

    /// Fades the leading edge only while the text is away from its start; the trailing edge always.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(offset < 0 ? 0 : 1), .black], startPoint: .leading, endPoint: .trailing).frame(width: 12)
            Color.black
            LinearGradient(colors: [.black, .black.opacity(0)], startPoint: .leading, endPoint: .trailing).frame(width: 16)
        }
    }

    private struct Cycle: Equatable { let text: String; let run: Bool; let distance: CGFloat }

    private func cycle() async {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { offset = 0 }
        // Snapshot tests turn UIKit animations off: keep the title at rest so images are stable.
        guard animates, !paused, UIView.areAnimationsEnabled else { return }
        let distance = textWidth + gap
        let duration = Self.glide(text: textWidth, gap: gap, speed: speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            // The second copy now sits exactly where the first started: jump back unseen.
            withTransaction(t) { offset = 0 }
        }
    }
}
