// Download UI: the collection toggle (outline arrow → accent progress ring → solid accent arrow),
// the small row glyphs (accent arrow when downloaded, ring while downloading). Spotify iOS:
// entity action row and the arrow before a row's artist line.
import SwiftUI

/// Entity-page download toggle. Tap downloads; tap when on asks "Remove from Downloads?"; tap when
/// some songs failed (and nothing is still going) retries them (`downloads_retry`).
struct DownloadButton: View {
    @Environment(AppModel.self) private var app
    let item: BrowseItem
    var size: CGFloat = 26

    var body: some View {
        let state = app.downloads.state(item.id)
        let paused: String? = if case .downloading = state { app.downloads.pausedReason } else { nil }
        Button {
            if case .failed = state { retryDownloads(app) } else { toggleDownload(app, item) }
        } label: {
            DownloadGlyph(state: state, size: size, paused: paused != nil)
        }
        .buttonStyle(PressScale(scale: 0.9))
        .accessibilityLabel(paused.map { "Download paused. \($0)" } ?? stateLabel(state))
        .accessibilityIdentifier("download-button")
    }

    private func stateLabel(_ s: DownloadState) -> String {
        switch s {
        case .none: "Download"
        case .downloading: "Downloading"
        case .done: "Remove download"
        case .failed(let n): n == 1 ? "1 song didn't download. Retry" : "\(n) songs didn't download. Retry"
        }
    }
}

/// The toggle's look for a state: outline arrow, accent progress ring, solid accent arrow, retry.
struct DownloadGlyph: View {
    let state: DownloadState
    var size: CGFloat = 26
    /// Downloading but not moving (offline, waiting for Wi-Fi): a pause mark in the ring.
    var paused = false
    var body: some View {
        Group {
            switch state {
            case .none:
                Icon(name: "arrow-circle-down", size: size).foregroundStyle(Palette.subdued)
            case .downloading(let f):
                ProgressRing(fraction: f, lineWidth: 2.2)
                    .frame(width: size - 3, height: size - 3)
                    .overlay(Image(systemName: paused ? "pause.fill" : "arrow.down").font(.system(size: size * 0.38, weight: .bold))
                        .foregroundStyle(paused ? Palette.subdued : Palette.accent))
                    .frame(width: size, height: size)
            case .done:
                Circle().fill(Palette.accent).frame(width: size - 2, height: size - 2)
                    .overlay(Image(systemName: "arrow.down").font(.system(size: size * 0.42, weight: .heavy)).foregroundStyle(.black))
                    .frame(width: size, height: size)
            case .failed:
                Icon(name: "arrow-clockwise", size: size).foregroundStyle(Palette.text)
            }
        }
        .animation(.easeOut(duration: 0.2), value: state)
    }
}

/// Retry every failed download, with a word either way.
@MainActor func retryDownloads(_ app: AppModel) {
    Haptics.impact(.light)
    let t = app.downloads.retry()
    Task { if await t.value { app.showToast("Trying the downloads again") } }
}

/// "N songs didn't download · Retry": drop it into a downloads or storage page. Hidden when nothing
/// failed.
struct DownloadsRetryRow: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let n = app.downloads.failedCount
        if n > 0 {
            HStack(spacing: Space.m) {
                Icon(name: "info", size: 20).foregroundStyle(Palette.subdued)
                Text(n == 1 ? "1 song didn't download" : "\(n) songs didn't download")
                    .font(Typo.font(14)).foregroundStyle(Palette.subdued)
                Spacer()
                Button("Retry") { retryDownloads(app) }
                    .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .accessibilityIdentifier("downloads-retry")
            }
            .padding(.horizontal, Space.gutter)
            .frame(minHeight: 48)
            .accessibilityElement(children: .contain)
        }
    }
}

/// Accent arc over a grey track (starts at 12 o'clock).
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 2
    var body: some View {
        ZStack {
            Circle().stroke(Palette.subdued.opacity(0.45), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.02, fraction))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.3), value: fraction)
        }
    }
}

/// The 14 pt glyph before a row's subtitle: accent arrow (downloaded) or a ring (downloading).
struct RowDownloadGlyph: View {
    @Environment(AppModel.self) private var app
    let videoId: String
    var body: some View {
        if app.downloads.isDownloaded(videoId) {
            Circle().fill(Palette.accent).frame(width: 13, height: 13)
                .overlay(Image(systemName: "arrow.down").font(.system(size: 7.5, weight: .black)).foregroundStyle(.black))
                .accessibilityLabel("Downloaded")
        } else if let p = app.downloads.active[videoId] {
            ProgressRing(fraction: p.total > 0 ? p.done / p.total : 0, lineWidth: 1.6).frame(width: 12, height: 12)
                .accessibilityLabel("Downloading")
        }
    }
}

/// The same glyph for a collection row in Your Library.
struct CollectionDownloadGlyph: View {
    @Environment(AppModel.self) private var app
    let id: String
    var body: some View {
        switch app.downloads.state(id) {
        case .none: EmptyView()
        case .downloading(let f): ProgressRing(fraction: f, lineWidth: 1.6).frame(width: 12, height: 12)
        case .done:
            Circle().fill(Palette.accent).frame(width: 13, height: 13)
                .overlay(Image(systemName: "arrow.down").font(.system(size: 7.5, weight: .black)).foregroundStyle(.black))
                .accessibilityLabel("Downloaded")
        case .failed:
            // The row itself opens the collection; Retry lives in the list above and in Storage.
            Icon(name: "arrow-clockwise", size: 13).foregroundStyle(Palette.subdued)
                .accessibilityLabel("Some songs didn't download")
        }
    }
}
