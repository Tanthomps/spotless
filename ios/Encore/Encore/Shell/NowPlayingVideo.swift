// Now Playing's music video / video podcast (stream ios-video, video-pods): the video in place of
// the cover, the "Switch to video" / "Switch to audio" pill, and the full-screen landscape view.
// State: `VideoStore`.
import SwiftUI

/// Spotify's pill under the cover: "Switch to video" on a song with a music video, "Switch to
/// audio" while the video plays. Only where there is a video (and not offline / Data Saver).
struct NPVideoSwitch: View {
    @Environment(AppModel.self) private var app
    var compact = false

    var body: some View {
        let video = VideoStore.shared
        let on = video.side
        Button { video.pick(!on) } label: {
            HStack(spacing: 6) {
                IconSwap(name: on ? "music-note" : "monitor-play", size: 16)
                Text(on ? "Switch to audio" : "Switch to video").font(Typo.font(13, .bold))
            }
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(Color.black.opacity(compact ? 0.45 : 0.28)))
            .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale(scale: 0.95))
        .accessibilityLabel(on ? "Switch to audio" : "Switch to video")
        .accessibilityIdentifier("np-video-switch")
        .accessibilityValue(on ? "video" : "audio")
    }
}

/// The video in the cover's square slot (inside `NPArtwork`'s carousel): 16:9, centred, so the
/// title row never moves. The video's own poster frame shows until mpv has drawn its first frame,
/// then the picture fades in.
struct NPVideoFrame: View {
    @Environment(AppModel.self) private var app
    let width: CGFloat

    var body: some View {
        let video = VideoStore.shared
        ZStack {
            Color.black
            ArtImage(url: poster, px: 1080, radius: 0)
                .opacity(video.frameUp ? 0 : 1)
            VideoSurface(active: !video.fullscreen && app.router.nowPlayingOpen)
                .opacity(video.frameUp ? 1 : 0)
            if !video.frameUp && video.switching != nil {
                ProgressView().tint(.white)
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .frame(width: width, height: width)
    }

    /// The video version's frame (the queue row trades art on a switch), else the cover.
    private var poster: String? {
        let s = app.player.current
        return s?.isVideo == true ? s?.thumbnail : (s?.counterpartThumbnail ?? s?.thumbnail)
    }
}

/// Spotify's controls over the inline video: a tap on the video dims it and shows the expand
/// arrows at the bottom right, the only way (besides turning the phone) into full screen. They hide
/// after 3 s or on a second tap (`NPArtwork` owns that). Spotify also has captions and a quality
/// gear there; the core has neither for these videos, so there are no buttons for them.
struct NPVideoChrome: View {
    let expand: () -> Void

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.black.opacity(0.45).allowsHitTesting(false)
            Button(action: expand) {
                Icon(name: "arrows-out-simple", size: 22).foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressScale(scale: 0.9))
            .padding(4)
            .accessibilityLabel("Full screen")
            .accessibilityIdentifier("np-video-expand")
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
    }
}

/// The full-screen video (Spotify's video podcasts): landscape, the picture letterboxed edge to
/// edge. A tap shows a dim overlay: show name and ⋯ at the top, −15 / play / +15 in the middle
/// (previous / next for a music video), title + show and collapse at the bottom over the chaptered
/// scrubber. It hides after 3 s of playing. Collapse or a swipe down: back to Now Playing.
struct VideoFullscreen: View {
    @Environment(AppModel.self) private var app
    @State private var chrome = true
    /// Bumped by every control press, so the overlay stays 3 s after the last one.
    @State private var pokes = 0
    @State private var dy: CGFloat = 0

    private struct HideKey: Equatable { var chrome: Bool; var paused: Bool; var pokes: Int }

    var body: some View {
        let video = VideoStore.shared
        let p = app.player
        ZStack {
            Color.black
            ArtImage(url: p.current?.thumbnail, px: 1080, radius: 0)
                .aspectRatio(16 / 9, contentMode: .fit)
                .opacity(video.frameUp ? 0 : 1)
            VideoSurface(active: true).opacity(video.frameUp ? 1 : 0)
        }
        .offset(y: max(0, dy))
        .background(Color.black)
        .ignoresSafeArea()
        .overlay { if chrome { overlay.transition(.opacity) } }
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { chrome.toggle() } }
        .gesture(swipeDown)
        .task(id: HideKey(chrome: chrome, paused: p.paused, pokes: pokes)) {
            guard chrome, !p.paused else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { chrome = false }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-video-fullscreen")
    }

    private var overlay: some View {
        let p = app.player
        let s = p.current
        let episode = s?.isEpisode == true
        let show = s?.artists ?? p.now?.artists ?? ""
        return ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack {
                    Text(episode ? show : (p.queue.sourceName ?? show)).font(Typo.font(15, .bold)).lineLimit(1)
                    Spacer()
                    Button { more() } label: {
                        Icon(name: "dots-three", size: 26).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("More options")
                    .accessibilityIdentifier("np-video-more")
                }
                Spacer()
                HStack(spacing: 64) {
                    if episode {
                        Button { poke(); app.player.seekBy(-15) } label: { SkipSeconds(forward: false) }
                            .accessibilityLabel("Back 15 seconds")
                    } else {
                        Button { poke(); p.skipPrevious() } label: { Icon(name: "skip-back", fill: true, size: 32).frame(width: 52, height: 52) }
                            .accessibilityLabel("Previous")
                    }
                    PlayCircleButton(playing: !p.paused, size: Metrics.npPlayButton, color: .white, loading: p.loading) { poke(); p.togglePause() }
                        .accessibilityIdentifier("np-video-play")
                    if episode {
                        Button { poke(); app.player.seekBy(15) } label: { SkipSeconds(forward: true) }
                            .accessibilityLabel("Forward 15 seconds")
                    } else {
                        Button { poke(); p.skipNext() } label: { Icon(name: "skip-forward", fill: true, size: 32).frame(width: 52, height: 52) }
                            .accessibilityLabel("Next")
                    }
                }
                .buttonStyle(PressScale(scale: 0.9))
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s?.title ?? p.now?.title ?? "").font(Typo.font(17, .bold)).lineLimit(1)
                        Text(show).font(Typo.font(14)).foregroundStyle(Palette.text.opacity(0.7)).lineLimit(1)
                    }
                    Spacer(minLength: Space.l)
                    Button { VideoStore.shared.exitFullscreen() } label: {
                        Icon(name: "arrows-in-simple", size: 24).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Exit full screen")
                    .accessibilityIdentifier("np-video-collapse")
                }
                Scrubber(showsChapter: true, onDrag: poke)
            }
            .foregroundStyle(Palette.text)
            // Now Playing ignores the safe area: room for the Dynamic Island (landscape inset ~62 pt
            // on either side) and the home indicator.
            .padding(.horizontal, 64)
            .padding(.top, Space.m)
            .padding(.bottom, Space.l)
        }
    }

    private func poke() { pokes += 1 }

    /// ⋯: back to Now Playing, and its options sheet there (sheets are portrait).
    private func more() {
        guard let s = app.player.current else { return }
        VideoStore.shared.exitFullscreen()
        Haptics.impact(.medium)
        app.sheet = .track(s, context: nil)
    }

    /// The picture follows the finger down; past ~100 pt or a flick it collapses.
    private var swipeDown: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { v in
                if v.translation.height > abs(v.translation.width) { dy = v.translation.height }
            }
            .onEnded { v in
                if dy > 100 || (dy > 20 && v.velocity.height > 800) {
                    VideoStore.shared.exitFullscreen()
                    dy = 0
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { dy = 0 }
                }
            }
    }
}

/// stream: video-pods. The mini player's live picture (Now Playing closed): 16:9 in the cover's
/// place, the poster until mpv's first frame (Spotify's video podcasts).
struct MiniVideoThumb: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let video = VideoStore.shared
        ZStack {
            Color.black
            ArtImage(url: app.player.current?.thumbnail ?? app.player.now?.thumbnail, px: 240, radius: 0)
                .opacity(video.frameUp ? 0 : 1)
            VideoSurface(active: !app.router.nowPlayingOpen)
                .opacity(video.frameUp ? 1 : 0)
        }
        .frame(width: Metrics.miniCover * 16 / 9, height: Metrics.miniCover)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(video.isEpisode ? "Episode video" : "Music video")
        .accessibilityValue(video.frameUp ? "playing" : "loading")
        .accessibilityIdentifier("mini-video")
    }
}
