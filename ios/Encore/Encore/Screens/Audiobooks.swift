// stream: audiobooks — LibriVox books on iOS (crates/core/src/audiobooks): the models, the saved
// books store, the book page, the chapter row and Now Playing's chapter card. A chapter is a
// podcast episode (`PODURL:` + MP3), so playback, resume, speed and downloads are the podcast path.
import SwiftUI

// MARK: models (core `audiobooks::{Audiobook, Resume, AudiobookPage}`)

struct Audiobook: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var author: String
    var narrator: String?
    var thumbnail: String?
    var description: String?
    var durationSecs: Double?
    var chapterCount: Int?
    var genres: [String]
    var language: String?
    var saved: Bool
    /// 0...1 of the book heard; nil before any listening.
    var progress: Double? = nil

    var card: BrowseItem { BrowseItem(kind: .audiobook, id: id, title: title, subtitle: author, thumbnail: thumbnail) }
}

struct AudiobookResume: Codable, Hashable {
    var index: Int
    var started: Bool
    var finished: Bool
}

struct AudiobookPage: Codable, Hashable {
    var book: Audiobook
    var chapters: [PodcastEpisode]
    var resume: AudiobookResume
    var librivoxUrl: String?
}

/// A chapter row's show id is `abook:<book id>`.
func audiobookId(fromShow showId: String?) -> String? {
    guard let s = showId, s.hasPrefix("abook:") else { return nil }
    return String(s.dropFirst("abook:".count))
}

// MARK: store

@MainActor @Observable
final class AudiobookStore {
    let core: CoreClient
    var saved: [Audiobook] = []
    @ObservationIgnored let actions: CoreActions

    init(core: CoreClient) { self.core = core; actions = CoreActions(core: core) }

    func refresh() async {
        if let v = try? await core.audiobookSaved() { saved = v }
    }

    func isSaved(_ id: String) -> Bool { saved.contains { $0.id == id } }

    @discardableResult
    func toggleSaved(_ book: Audiobook) -> Bool {
        let on = !isSaved(book.id)
        let before = saved
        if on { var b = book; b.saved = true; saved.insert(b, at: 0) } else { saved.removeAll { $0.id == book.id } }
        actions.run("audiobook-save", on ? "Couldn't add this audiobook" : "Couldn't remove this audiobook", revert: { [weak self] in self?.saved = before }) { [core] in
            try await core.audiobookSave(book, saved: on)
        }
        return on
    }
}

/// Play the book from chapter `index` (default: where it was left); the chapter's saved position
/// resumes in the core like any episode's.
@MainActor func playBook(_ app: AppModel, _ page: AudiobookPage, at index: Int? = nil) {
    let i = index ?? page.resume.index
    guard page.chapters.indices.contains(i) else { return }
    if app.player.now?.videoId == page.chapters[i].id { app.player.togglePause(); return }
    app.player.play(page.chapters.map(\.song), at: i, context: PlayContext(kind: .audiobook, id: page.book.id, title: page.book.title))
}

@MainActor func toggleBookDownload(_ app: AppModel, _ page: AudiobookPage) {
    let id = "abook:\(page.book.id)"
    if app.downloads.isCollectionDownloaded(id) {
        app.confirm = ConfirmRequest(title: "Remove from Downloads?", message: "You won't be able to play this offline.", action: "Remove") {
            app.downloads.remove(id)
        }
    } else {
        app.downloads.add(DownloadCollection(id: id, kind: "audiobook", title: page.book.title, subtitle: page.book.author, thumbnail: page.book.thumbnail),
                          songs: page.chapters.map(\.song))
        Haptics.impact(.light)
    }
}

// MARK: chapter row

/// Number (equalizer while playing), title, "18 min" / "5 min left" with a progress line, a check
/// once heard. A tap plays the chapter.
struct BookChapterRow: View {
    @Environment(AppModel.self) private var app
    let chapter: PodcastEpisode
    let number: Int
    var onPlay: () -> Void

    var body: some View {
        let p = app.podcasts.progressOf(chapter)
        let dur = chapter.durationSecs ?? p.durationSecs
        let current = app.player.now?.videoId == chapter.id
        Button(action: onPlay) {
            HStack(spacing: Space.m) {
                Group {
                    if current { EqualizerGlyph(animating: !app.player.paused) } else { Text("\(number)").monospacedDigit() }
                }
                .font(Typo.font(15)).foregroundStyle(current ? Palette.accentText : Palette.subdued).frame(width: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(chapter.title).font(Typo.rowTitle).foregroundStyle(current ? Palette.accentText : Palette.text).lineLimit(2)
                    HStack(spacing: 6) {
                        if p.played {
                            Icon(name: "check-circle", fill: true, size: 14).foregroundStyle(Palette.accent)
                            Text("Finished").foregroundStyle(Palette.accentText)
                        } else if p.started {
                            ProgressLine(fraction: p.fraction, color: Palette.text).frame(width: 52)
                            Text("\(episodeLength(max(0, dur - p.positionSecs))) left")
                        } else if dur > 0 {
                            Text(episodeLength(dur))
                        }
                    }
                    .font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
                IconSwap(name: current && !app.player.paused ? "pause-circle" : "play-circle", fill: true, size: 30)
                    .foregroundStyle(Palette.text)
            }
            .padding(.horizontal, Space.gutter).padding(.vertical, Space.s + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Chapter \(number), \(chapter.title)")
        .accessibilityIdentifier("book-chapter")
    }
}

// MARK: book page

struct AudiobookView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var page: AudiobookPage?
    @State private var failed = false
    @State private var attempt = 0
    @State private var aboutExpanded = false

    var body: some View {
        let playingThis = page?.chapters.contains { $0.id == app.player.now?.videoId } ?? false
        EntityScaffold(title: page?.book.title ?? "", artURL: page?.book.thumbnail, isPlayingThis: playingThis, onPlay: play) { off in
            header(off, playing: playingThis && !app.player.paused)
        } content: {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let page, page.chapters.isEmpty {
                    EntityEmptyState(title: "No chapters available", line: "This audiobook has nothing to play yet.")
                } else if let page {
                    Text("Chapters").font(Typo.font(18, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.xs)
                    ForEach(Array(page.chapters.enumerated()), id: \.element.id) { i, c in
                        BookChapterRow(chapter: c, number: i + 1) { playBook(app, page, at: i) }
                    }
                } else {
                    EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                }
            }
        }
        .task(id: "\(id)#\(attempt)#\(app.player.now?.videoId ?? "")") {
            do {
                page = try await app.core.audiobookPage(id: id)
                failed = false
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load this audiobook")
                failed = page == nil
            } catch {}
        }
        .accessibilityIdentifier("audiobook-page")
    }

    private func play() {
        guard let page else { return }
        if page.chapters.contains(where: { $0.id == app.player.now?.videoId }) { app.player.togglePause(); return }
        playBook(app, page)
    }

    private func header(_ offset: CGFloat, playing: Bool) -> some View {
        let shrink = max(0.6, min(1, 1 - offset / 400))
        let book = page?.book
        let saved = book.map { app.books.isSaved($0.id) } ?? false
        let downloaded = book.map { app.downloads.isCollectionDownloaded("abook:\($0.id)") } ?? false
        let resume = page?.resume
        let resuming = resume.map { $0.started && !$0.finished } ?? false
        return VStack(alignment: .leading, spacing: Space.s) {
            ArtImage(url: book?.thumbnail, px: 720, radius: Radius.m)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .scaleEffect(shrink, anchor: .bottom)
                .opacity(Double(min(1, max(0, 1.4 - offset / 220))))
                .frame(maxWidth: .infinity)
                .padding(.top, 96)
                .padding(.bottom, Space.s)
            Text(book?.title ?? " ").font(Typo.font(24, .bold)).lineLimit(3).accessibilityAddTraits(.isHeader)
            Text(book?.author ?? " ").font(Typo.font(15, .semibold))
            if let n = book?.narrator { Text("Read by \(n)").font(Typo.font(13)).foregroundStyle(Palette.subdued) }
            Text(["Audiobook", book?.durationSecs.map(episodeLength) ?? "", book?.chapterCount.map { "\($0) chapters" } ?? ""]
                .filter { !$0.isEmpty }.joined(separator: " • "))
                .font(Typo.font(13)).foregroundStyle(Palette.subdued)
            HStack(spacing: Space.l + 4) {
                Button {
                    guard let book else { return }
                    let on = app.books.toggleSaved(book)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                } label: {
                    IconSwap(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 28).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .disabled(book == nil)
                .accessibilityLabel(saved ? "Remove from Your Library" : "Add to Your Library")
                .accessibilityIdentifier("book-save")
                // Same toggle as albums: progress ring while it downloads, paused look, Retry on failures.
                let dl = book.map { app.downloads.state("abook:\($0.id)") } ?? .none
                let paused: String? = if case .downloading = dl { app.downloads.pausedReason } else { nil }
                Button {
                    guard let page else { return }
                    if case .failed = dl { retryDownloads(app) } else { toggleBookDownload(app, page) }
                } label: {
                    DownloadGlyph(state: downloaded && dl == .none ? .downloading(0) : dl, size: 28, paused: paused != nil)
                }
                .buttonStyle(PressScale(scale: 0.9))
                .disabled(page == nil)
                .accessibilityLabel(paused.map { "Download paused. \($0)" } ?? {
                    switch dl {
                    case .none: "Download"
                    case .downloading: "Downloading"
                    case .done: "Remove download"
                    case .failed(let n): n == 1 ? "1 chapter didn't download. Retry" : "\(n) chapters didn't download. Retry"
                    }
                }())
                Spacer()
                PlayCircleButton(playing: playing, action: play).modifier(PlayAnchor())
                    .disabled(page?.chapters.isEmpty == true)
                    .opacity(page?.chapters.isEmpty == true ? 0.4 : 1)
                    .accessibilityLabel(playing ? "Pause" : resuming ? "Resume" : "Play")
                    .accessibilityIdentifier("entity-play")
            }
            .padding(.top, Space.xs)
            if resuming, let page, let r = resume, page.chapters.indices.contains(r.index) {
                Button(action: play) {
                    HStack(spacing: 4) {
                        Text("Resume:").foregroundStyle(Palette.subdued)
                        Text(page.chapters[r.index].title).foregroundStyle(Palette.text).bold().lineLimit(1)
                        if let f = page.book.progress, f >= 0.01 { Text("• \(Int((f * 100).rounded()))% heard").foregroundStyle(Palette.subdued) }
                    }
                    .font(Typo.font(13))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("book-resume")
            }
            if let d = book?.description, !d.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("About this audiobook").font(Typo.font(18, .bold))
                    Text(d).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(aboutExpanded ? nil : 4).clipped()
                    Button(aboutExpanded ? "Show less" : "Show more") { withAnimation(Motion.quick) { aboutExpanded.toggle() } }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.s) {
                            ForEach((book?.genres ?? []) + [book?.language ?? "", "Public domain • LibriVox"].filter { !$0.isEmpty }, id: \.self) { g in
                                Text(g).font(Typo.font(13)).padding(.horizontal, 12).frame(height: 30)
                                    .background(Capsule().fill(Color(hex: "#2a2a2a")))
                            }
                        }
                    }
                }
                .padding(.top, Space.m)
            }
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
    }
}

// MARK: Now Playing

/// The playing book's chapters around the current one, "Show all" for the rest. Hidden for
/// anything that isn't a book chapter.
struct BookChaptersCard: View {
    @Environment(AppModel.self) private var app
    @State private var page: AudiobookPage?
    @State private var expanded = false

    var body: some View {
        let now = app.player.current?.isEpisode == true ? app.player.current?.videoId : nil
        // A VStack, not a Group: an empty Group has no view, so its `.task` would never run.
        VStack(spacing: 0) {
            if let page, let now, let active = page.chapters.firstIndex(where: { $0.id == now }), page.chapters.count > 1 {
                let start = expanded ? 0 : max(0, min(active, page.chapters.count - 3))
                let end = expanded ? page.chapters.count : min(page.chapters.count, start + 3)
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chapters").font(Typo.font(16, .bold))
                            Text("\(page.book.title) • \(active + 1) of \(page.chapters.count)").font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1)
                        }
                        Spacer()
                        if page.chapters.count > 3 {
                            Button(expanded ? "Show less" : "Show all") { withAnimation(Motion.quick) { expanded.toggle() } }
                                .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 16).frame(height: 32)
                                .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
                        }
                    }
                    VStack(spacing: 0) {
                        ForEach(start..<end, id: \.self) { i in
                            BookChapterRow(chapter: page.chapters[i], number: i + 1) { playBook(app, page, at: i) }
                                .padding(.horizontal, -Space.gutter)
                        }
                    }
                }
                .foregroundStyle(Palette.text)
                .padding(Space.l)
                .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.elevatedHighlight))
                .padding(.horizontal, Space.gutter)
                .accessibilityIdentifier("np-book-chapters")
            }
        }
        .task(id: now) {
            guard let now, now.hasPrefix("PODURL:") else { page = nil; return }
            if page?.chapters.contains(where: { $0.id == now }) == true { return }
            page = try? await app.core.audiobookForChapter(id: now)
        }
    }
}
