// Floating mini player above the tab bar: artwork-tinted card, title/artist carousel (swipe left/right
// skips), tap or swipe up opens Now Playing, 2pt progress line along the bottom edge.
import SwiftUI

struct MiniPlayer: View {
    @Environment(AppModel.self) private var app
    @State private var accent: UIColor?
    @State private var dx: CGFloat = 0
    @State private var axis: Axis?
    @State private var dy: CGFloat = 0
    @State private var textWidth: CGFloat = 200

    private var player: PlayerStore { app.player }
    private var device: String? { AudioRoute.shared.externalName }

    var body: some View {
        let song = player.current
        HStack(spacing: Space.s + 2) {
            // stream: video-pods. A video showing (video podcast, music video) plays here, live.
            if VideoStore.shared.miniShowsVideo {
                MiniVideoThumb()
            } else {
                ArtImage(url: song?.thumbnail ?? player.now?.thumbnail, px: 120, radius: Radius.s)
                    .frame(width: Metrics.miniCover, height: Metrics.miniCover)
                    .id(song?.thumbnail)
                    .transition(.opacity)
                    .opacity(ArtFlight.shared.flying ? 0 : 1)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { ArtFlight.shared.mini = $0 }
            }
            GeometryReader { geo in
                carousel(width: geo.size.width)
            }
            .frame(height: Metrics.miniCover)
            .clipped()
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(song.map { "\($0.title), \(device.map { "playing on \($0)" } ?? $0.artists)" } ?? "")
            .accessibilityValue(song?.title ?? "")
            .accessibilityHint("Opens Now Playing. Swipe left or right to skip.")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("mini-player-text")
            // Buttons: 44 pt hit areas around 24 pt glyphs, trailing inset 8 (Spotify's ~47 pt pitch).
            HStack(spacing: 0) {
                // Accent when the audio goes to another device (AirPlay, Bluetooth).
                Icon(name: "devices", size: 24).foregroundStyle(device == nil ? Palette.text : Palette.accent).frame(width: 44, height: 44)
                    .routePickerOverlay()
                    .accessibilityIdentifier("mini-devices")
                if let s = song {
                    let liked = app.library.isLiked(s.videoId)
                    Button { app.likeButton(s) } label: {
                        IconSwap(name: liked ? "check-circle" : "plus-circle", fill: liked, size: 24)
                            .foregroundStyle(liked ? Palette.accent : Palette.text).frame(width: 44, height: 44)
                            .pulse(on: liked)
                    }
                    .accessibilityLabel(liked ? "Saved in Liked Songs" : "Add to Liked Songs")
                    .accessibilityHint(liked ? "Opens Add to playlist" : "")
                    .accessibilityIdentifier("mini-like")
                }
                Button { player.togglePause() } label: {
                    // stream: instant: the tapped track is up already; this spins until it sounds.
                    Group {
                        if player.loading {
                            ProgressView().tint(Palette.text)
                        } else {
                            IconSwap(name: player.paused ? "play" : "pause", fill: true, size: 24).foregroundStyle(Palette.text)
                        }
                    }
                    .frame(width: 44, height: 44)
                }
                .accessibilityLabel(player.loading ? "Loading" : player.paused ? "Play" : "Pause")
                .accessibilityIdentifier("mini-play")
            }
        }
        .padding(.leading, Space.s)
        .padding(.trailing, Space.xs + 2)
        .frame(height: Metrics.miniPlayerHeight)
        .background {
            RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                .fill(accent?.surface(value: 0.36, maxSaturation: 0.65) ?? Color(hex: "#3a3a3a"))
        }
        .overlay(alignment: .bottom) { progressLine }
        .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
        .offset(y: min(0, dy) * 0.25)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .gesture(drag)
        .artAccent(song?.thumbnail ?? player.now?.thumbnail, into: $accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mini-player")
        .onChange(of: player.queue.currentIndex) { _, _ in
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { dx = 0 }
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.25))
                Capsule().fill(Color.white).frame(width: geo.size.width * player.progress)
            }
        }
        // 2 pt along the card's bottom inside edge, inset 8 left and right.
        .frame(height: 2)
        .padding(.horizontal, Space.s)
        .accessibilityHidden(true)
    }

    /// Previous · current · next titles side by side; the drag slides the strip.
    private func carousel(width w: CGFloat) -> some View {
        HStack(spacing: 0) {
            titleBlock(player.previous).frame(width: w)
            titleBlock(player.current, live: true).frame(width: w)
            titleBlock(player.next).frame(width: w)
        }
        .offset(x: -w + dx)
        .frame(width: w, alignment: .leading)
        .onAppear { textWidth = w }
        .onChange(of: w) { _, n in textWidth = n }
    }

    /// `live`: the playing item. Its long title marquees, and its second line names the output
    /// device in accent when that isn't the phone. The neighbours stay plain (they're off-card).
    private func titleBlock(_ s: SongItem?, live: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if live {
                Marquee(text: s?.title ?? "", font: Typo.miniTitle, paused: dx != 0)
            } else {
                Text(s?.title ?? "").font(Typo.miniTitle).foregroundStyle(Palette.text).lineLimit(1)
            }
            if live, let device {
                HStack(spacing: 4) {
                    Icon(name: "speaker-high", fill: true, size: 12)
                    Text(device).font(Typo.miniArtist).lineLimit(1)
                }
                .foregroundStyle(Palette.accent)
                .accessibilityIdentifier("mini-device")
            } else {
                Text(s?.artists ?? "").font(Typo.miniArtist).foregroundStyle(Palette.text.opacity(0.7)).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 4)
    }

    private func open() {
        withAnimation(Motion.spring) { app.router.nowPlayingOpen = true }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                if axis == nil { axis = abs(v.translation.width) > abs(v.translation.height) ? .horizontal : .vertical }
                if axis == .horizontal {
                    var x = v.translation.width
                    if x > 0 && player.previous == nil { x *= 0.25 }
                    if x < 0 && player.next == nil { x *= 0.25 }
                    dx = x
                } else {
                    dy = v.translation.height
                }
            }
            .onEnded { v in
                defer { axis = nil }
                if axis == .vertical {
                    let up = v.translation.height < -30 || v.predictedEndTranslation.height < -80
                    withAnimation(Motion.spring) { dy = 0 }
                    if up { open() }
                    return
                }
                let w = textWidth
                let fling = v.predictedEndTranslation.width
                if (v.translation.width < -w * 0.3 || fling < -w * 0.7), player.next != nil {
                    commit(direction: 1, width: w)
                } else if (v.translation.width > w * 0.3 || fling > w * 0.7), player.previous != nil {
                    commit(direction: -1, width: w)
                } else {
                    withAnimation(Motion.spring) { dx = 0 }
                }
            }
    }

    /// Slide the strip all the way, then skip; `onChange(currentIndex)` snaps it back under the new track.
    private func commit(direction: Int, width: CGFloat) {
        withAnimation(.easeOut(duration: 0.18)) { dx = direction > 0 ? -width : width }
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if direction > 0 { player.skipNext() } else { player.playIndex(player.queue.currentIndex - 1) }
            try? await Task.sleep(nanoseconds: 800_000_000)
            if dx != 0 { withAnimation(Motion.spring) { dx = 0 } }
        }
    }
}
