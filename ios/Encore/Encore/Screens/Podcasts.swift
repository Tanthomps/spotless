// Podcasts (docs/streams/podcasts.md on iOS): show page, episode page, Your Episodes / New Episodes,
// the episode row (save, download, ⋯, play; progress bar + "N min left"; played check), the playback
// speed sheet, the episode/show sheets, search results and the Home "Podcasts" chip.
// Episodes play as queue rows built by `PodcastEpisode.song` (`is_episode`), with no source id.
import SwiftUI

// MARK: helpers

/// `startSecs` starts the episode that far in (a chapter or show-notes timestamp), in the play call.
@MainActor func playEpisodes(_ app: AppModel, _ list: [PodcastEpisode], at i: Int, startSecs: Double? = nil) {
    guard list.indices.contains(i) else { return }
    if app.player.now?.videoId == list[i].id {
        if let startSecs { app.player.seek(startSecs) } else { app.player.togglePause() }
        return
    }
    app.player.play(list.map(\.song), at: i, context: PlayContext(kind: .song, id: nil, title: list[i].showTitle), startSecs: startSecs)
}

/// Download an episode, or (Spotify asks first) remove its download; Retry once it failed. The core
/// also saves a downloaded episode to Your Episodes; removing the download keeps it saved.
@MainActor func toggleEpisodeDownload(_ app: AppModel, _ e: PodcastEpisode) { toggleEpisodeDownload(app, song: e.song, episode: e) }

/// From a queue row (search results, Now Playing): `episode` is only there to show it saved at once.
@MainActor func toggleEpisodeDownload(_ app: AppModel, song s: SongItem, episode: PodcastEpisode? = nil) {
    switch app.downloads.state(s.videoId) {
    case .failed: retryDownloads(app)
    case .done, .downloading:
        app.confirm = ConfirmRequest(title: "Remove from Downloads?", message: "You won't be able to play this offline.", action: "Remove") {
            app.downloads.remove(s.videoId)
        }
    case .none:
        // Saved with the download (the core does both); a refused download takes the save back too.
        let wasSaved = episode.map { app.podcasts.isSaved($0) } ?? true
        if let episode, !wasSaved { app.podcasts.saved.insert(episode, at: 0) }
        let t = app.downloads.add(DownloadCollection(id: s.videoId, kind: "episode", title: s.title, subtitle: s.artists, thumbnail: s.thumbnail),
                                  songs: [s]) { [podcasts = app.podcasts] in await podcasts.refresh() }
        Task { if await t.value == false, !wasSaved { app.podcasts.saved.removeAll { $0.id == s.videoId } } }
        Haptics.impact(.light)
        DownloadKeeper.shared.userStartedDownload(title: s.title)
    }
}

/// The episode sheet's Download row, with the toggle's states.
@MainActor func episodeDownloadRow(_ app: AppModel, song s: SongItem, episode: PodcastEpisode? = nil) -> SheetRow {
    let (icon, title, on): (String, String, Bool) = switch app.downloads.state(s.videoId) {
    case .none: ("arrow-circle-down", "Download", false)
    case .downloading: ("arrow-circle-down", "Downloading…", true)
    case .done: ("arrow-circle-down", "Remove download", true)
    case .failed: ("arrow-clockwise", "Retry download", false)
    }
    return SheetRow(icon: icon, fill: on, title: title, tint: on ? Palette.accent : Palette.text) {
        toggleEpisodeDownload(app, song: s, episode: episode)
    }
}

/// The episode row / page download toggle: outline arrow, accent ring while downloading, solid accent.
struct EpisodeDownloadButton: View {
    @Environment(AppModel.self) private var app
    let episode: PodcastEpisode
    var size: CGFloat = 24
    var body: some View {
        let state = app.downloads.state(episode.id)
        Button { toggleEpisodeDownload(app, episode) } label: { DownloadGlyph(state: state, size: size) }
            .buttonStyle(PressScale(scale: 0.9))
            .accessibilityLabel({
                switch state {
                case .none: "Download"
                case .done: "Remove download"
                case .downloading: "Downloading"
                case .failed: "Download failed. Retry download"
                }
            }())
            .accessibilityIdentifier("episode-download")
    }
}

/// "Nov 3 • 38 min" / progress / played, as one line.
struct EpisodeMeta: View {
    @Environment(AppModel.self) private var app
    let episode: PodcastEpisode
    var body: some View {
        let p = app.podcasts.progressOf(episode)
        let dur = episode.durationSecs ?? p.durationSecs
        HStack(spacing: 6) {
            RowDownloadGlyph(videoId: episode.id)
            if p.played {
                Icon(name: "check-circle", fill: true, size: 14).foregroundStyle(Palette.accent)
                Text("Played").foregroundStyle(Palette.accentText)
                Text("• \(episodeDate(episode.publishedAt))")
            } else if p.started {
                Text(episodeDate(episode.publishedAt))
                Text("•")
                ProgressLine(fraction: p.fraction).frame(width: 52)
                Text("\(episodeLength(max(0, dur - p.positionSecs))) left")
            } else {
                Text([episodeDate(episode.publishedAt), dur > 0 ? episodeLength(dur) : ""].filter { !$0.isEmpty }.joined(separator: " • "))
            }
        }
        .font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1)
    }
}

/// Thin progress bar for a started episode.
struct ProgressLine: View {
    let fraction: Double
    var color: Color = Palette.accent
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.3))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 3)
        .accessibilityLabel("\(Int(fraction * 100)) percent played")
    }
}

/// Spotify iOS episode row: art + title + show, description, meta, then save / download / ⋯ and play.
struct EpisodeRow: View {
    @Environment(AppModel.self) private var app
    let episode: PodcastEpisode
    var showShowTitle = true
    var showDescription = true
    var onPlay: () -> Void

    var body: some View {
        let isCurrent = app.player.now?.videoId == episode.id
        let saved = app.podcasts.isSaved(episode)
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                ArtImage(url: episode.thumbnail, px: 200, radius: Radius.m).frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.title).font(Typo.font(15, .bold)).lineLimit(2)
                        .foregroundStyle(isCurrent ? Palette.accentText : Palette.text)
                    if showShowTitle { Text(episode.showTitle).font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            if showDescription, let d = episode.description, !d.isEmpty {
                Text(plainText(d)).font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(2)
            }
            EpisodeMeta(episode: episode)
            HStack(spacing: Space.xl) {
                Button {
                    let on = app.podcasts.toggleSaved(episode)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Episodes" : "Removed from Your Episodes")
                } label: {
                    IconSwap(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 24).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .accessibilityLabel(saved ? "Remove from Your Episodes" : "Add to Your Episodes")
                EpisodeDownloadButton(episode: episode)
                Button { app.sheet = .episode(episode) } label: {
                    Icon(name: "dots-three", size: 24).foregroundStyle(Palette.subdued)
                }
                .accessibilityLabel("More options for \(episode.title)")
                Spacer()
                Button(action: onPlay) {
                    Circle().fill(Color.white).frame(width: 32, height: 32)
                        .overlay(IconSwap(name: isCurrent && !app.player.paused ? "pause" : "play", fill: true, size: 14).foregroundStyle(.black)
                            .offset(x: isCurrent && !app.player.paused ? 0 : 1))
                }
                .buttonStyle(PressScale(scale: 0.92))
                .accessibilityLabel(isCurrent && !app.player.paused ? "Pause" : "Play \(episode.title)")
                .accessibilityIdentifier("episode-play")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.m)
        .contentShape(Rectangle())
        .onTapGesture { app.router.push(.episode(episode.id)) }
        .accessibilityAddTraits(.isButton)
        .onLongPressGesture(minimumDuration: 0.4) { Haptics.impact(.medium); app.sheet = .episode(episode) }
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 0.5).padding(.horizontal, Space.gutter) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("episode-row")
    }
}

// MARK: show notes (sanitised HTML → AttributedString with tappable links and timestamps)

private let entities: [(String, String)] = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")]

func decodeEntities(_ s: String) -> String { entities.reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) } }

/// The notes without markup (for 2-line previews).
func plainText(_ html: String) -> String {
    var s = html.replacingOccurrences(of: #"<br\s*/?>|</p>"#, with: " ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    return decodeEntities(s).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
}

/// `<a href="#t=SECS" data-seek="SECS">` become `encore-seek://SECS` links; other links stay.
func showNotes(_ html: String) -> AttributedString {
    var s = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: .regularExpression)
    s = s.replacingOccurrences(of: #"</p>\s*"#, with: "\n\n", options: .regularExpression)
    s = s.replacingOccurrences(of: #"<li[^>]*>"#, with: "• ", options: .regularExpression)
    s = s.replacingOccurrences(of: #"</li>"#, with: "\n", options: .regularExpression)
    var out = AttributedString()
    let link = try! NSRegularExpression(pattern: #"<a\b([^>]*)>(.*?)</a>"#, options: [.dotMatchesLineSeparators, .caseInsensitive])
    let ns = s as NSString
    var last = 0
    func text(_ raw: String) -> AttributedString {
        AttributedString(decodeEntities(raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)))
    }
    for m in link.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
        out += text(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
        let attrs = ns.substring(with: m.range(at: 1))
        var piece = text(ns.substring(with: m.range(at: 2)))
        if let seek = attrs.firstMatch(#"data-seek="(\d+(?:\.\d+)?)""#) ?? attrs.firstMatch(##"href="#t=(\d+(?:\.\d+)?)""##) {
            piece.link = URL(string: "encore-seek://\(seek)")
            piece.foregroundColor = Palette.accentText
        } else if let href = attrs.firstMatch(#"href="([^"]+)""#), let u = URL(string: decodeEntities(href)) {
            piece.link = u
            piece.foregroundColor = Palette.text
            piece.underlineStyle = .single
        }
        out += piece
        last = m.range.location + m.range.length
    }
    out += text(ns.substring(from: last))
    return out
}

private extension String {
    func firstMatch(_ pattern: String) -> String? {
        guard let r = try? NSRegularExpression(pattern: pattern), let m = r.firstMatch(in: self, range: NSRange(startIndex..., in: self)),
              m.numberOfRanges > 1, let g = Range(m.range(at: 1), in: self) else { return nil }
        return String(self[g])
    }
}

// MARK: show page

struct ShowView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var page: PodcastShowPage?
    @State private var sort: EpisodeSort = .newest
    @State private var aboutExpanded = false
    @State private var failed = false
    @State private var attempt = 0
    @State private var moreFailed = false

    var body: some View {
        let eps = page?.episodes ?? []
        let playingThis = eps.contains { $0.id == app.player.now?.videoId }
        EntityScaffold(title: page?.show.title ?? "", artURL: page?.show.thumbnail, isPlayingThis: playingThis, onPlay: playLatest) { off in
            header(off, playing: playingThis && !app.player.paused)
        } content: {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("All episodes").font(Typo.font(18, .bold))
                    Spacer()
                    Menu {
                        Picker("Sort", selection: $sort) {
                            Text("Newest first").tag(EpisodeSort.newest)
                            Text("Oldest first").tag(EpisodeSort.oldest)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Icon(name: "arrows-down-up", size: 14)
                            Text(sort == .newest ? "Newest" : "Oldest").font(Typo.font(13, .semibold))
                        }
                        .foregroundStyle(Palette.text)
                    }
                    .accessibilityIdentifier("show-sort")
                }
                .padding(.horizontal, Space.gutter)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xs)
                ForEach(Array(eps.enumerated()), id: \.element.id) { i, e in
                    EpisodeRow(episode: e, showShowTitle: false) { playEpisodes(app, eps, at: i) }
                        .onAppear { if i >= eps.count - 3 { loadMore() } }
                }
                if page == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                if let page, page.episodes.isEmpty {
                    Text("No episodes yet").font(Typo.font(16, .bold)).frame(maxWidth: .infinity).padding(.top, Space.xxl)
                        .accessibilityIdentifier("show-empty")
                }
                if moreFailed {
                    Button { moreFailed = false; loadMore() } label: {
                        Text("Couldn't load more episodes. Try again").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                            .frame(maxWidth: .infinity).frame(height: 56)
                    }
                    .accessibilityIdentifier("show-more-retry")
                }
            }
        }
        .task(id: "\(id)|\(sort.rawValue)#\(attempt)") {
            do {
                page = try await app.core.podcastShow(id: id, sort: sort)
                failed = false
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load this show")
                failed = true
            } catch {}
        }
    }

    @State private var loadingMore = false
    /// The next page when the list nears its end (`podcast_show_more`).
    private func loadMore() {
        guard !loadingMore, let p = page, let token = p.continuation else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            do {
                let more = try await app.core.podcastShowMore(id: id, continuation: token, sort: sort)
                guard page?.continuation == token else { return }
                page?.episodes += more.episodes
                page?.continuation = more.continuation
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load more episodes")
                moreFailed = true
            } catch {}
        }
    }

    private func header(_ offset: CGFloat, playing: Bool) -> some View {
        let shrink = max(0.6, min(1, 1 - offset / 400))
        let show = page?.show
        let followed = show.map { app.podcasts.isFollowed($0.id) } ?? false
        return VStack(alignment: .leading, spacing: Space.m) {
            ArtImage(url: show?.thumbnail, px: 720, radius: Radius.l)
                .frame(width: 200, height: 200)
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
                .scaleEffect(shrink, anchor: .bottom)
                .opacity(Double(min(1, max(0, 1.4 - offset / 220))))
                .frame(maxWidth: .infinity)
                .padding(.top, 96)
                .padding(.bottom, Space.s)
            Text(show?.title ?? " ").font(Typo.font(26, .bold)).lineLimit(2).accessibilityAddTraits(.isHeader)
            Text(show?.author ?? " ").font(Typo.font(14, .semibold)).foregroundStyle(Palette.subdued)
            HStack(spacing: Space.l + 4) {
                Button {
                    guard let show else { return }
                    let on = app.podcasts.toggleFollow(show)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                } label: {
                    Text(followed ? "Following" : "Follow").font(Typo.font(13, .bold)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 14).frame(height: 32)
                        .overlay(Capsule().stroke(followed ? Palette.text : Palette.dim, lineWidth: 1))
                }
                .disabled(show == nil) // nothing to follow until the show has loaded
                .accessibilityIdentifier("show-follow")
                Button { if let show { app.sheet = .show(show) } } label: { Icon(name: "dots-three", size: 26) }
                    .accessibilityLabel("More options")
                Spacer()
                PlayCircleButton(playing: playing, action: playLatest).modifier(PlayAnchor())
                    .accessibilityIdentifier("entity-play")
            }
            .foregroundStyle(Palette.subdued)
            if let d = show?.description, !d.isEmpty {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("About").font(Typo.font(18, .bold))
                    Text(d).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(aboutExpanded ? nil : 3).clipped()
                    Button(aboutExpanded ? "Show less" : "Show more") { withAnimation(Motion.quick) { aboutExpanded.toggle() } }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                }
                .padding(.top, Space.s)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
    }

    /// Spotify plays the latest unplayed episode (or resumes the one in progress).
    private func playLatest() {
        let eps = page?.episodes ?? []
        if let i = eps.firstIndex(where: { $0.id == app.player.now?.videoId }) { playEpisodes(app, eps, at: i); return }
        let i = eps.firstIndex { app.podcasts.progressOf($0).started } ?? eps.firstIndex { !app.podcasts.progressOf($0).played } ?? 0
        playEpisodes(app, eps, at: i)
    }
}

// MARK: chapters (stream: chapters)

/// Chapter rows: optional art, title (accent while it plays) and start time. A tap jumps there.
struct ChapterRows: View {
    let chapters: [PodcastChapter]
    var active = -1
    /// Index of `chapters[0]` in the full list, when showing a slice.
    var offset = 0
    let onPick: (PodcastChapter) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(chapters.enumerated()), id: \.element.startSecs) { i, c in
                let on = offset + i == active
                Button { onPick(c) } label: {
                    HStack(spacing: Space.m) {
                        if let img = c.img { ArtImage(url: img, px: 144, radius: Radius.xs).frame(width: 40, height: 40) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(Typo.rowTitle).foregroundStyle(on ? Palette.accentText : Palette.text).lineLimit(2)
                            Text(c.startLabel).font(Typo.rowSubtitle).monospacedDigit().foregroundStyle(Palette.subdued)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.title), \(c.startLabel)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// Spotify's Chapters sheet for the playing episode: "Chapters" (and "These chapters are
/// auto-generated." when YouTube made them), then a row per chapter: its frame (YouTube's chapter
/// thumbnail, else the episode's art), the title on up to two lines and its length; the playing one
/// in accent. A tap jumps there.
struct ChaptersSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let p = app.player
        let id = p.current?.isEpisode == true ? p.current?.videoId ?? "" : ""
        let list = app.podcasts.chapters[id] ?? []
        let active = chapterAt(list, p.position)
        let art = p.current?.thumbnail ?? p.now?.thumbnail
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Chapters").font(Typo.font(20, .bold)).accessibilityAddTraits(.isHeader)
                if app.podcasts.chaptersAuto.contains(id) {
                    Text("These chapters are auto-generated.").font(Typo.font(13)).foregroundStyle(Palette.subdued)
                        .accessibilityIdentifier("chapters-auto")
                }
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.m)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(list.enumerated()), id: \.element.startSecs) { i, c in
                            row(c, on: i == active, art: art).id(i)
                        }
                    }
                    .padding(.bottom, Space.l)
                }
                .onAppear { if active > 2 { proxy.scrollTo(active, anchor: .center) } }
            }
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chapters-sheet")
    }

    private func row(_ c: PodcastChapter, on: Bool, art: String?) -> some View {
        Button {
            Haptics.selection()
            app.player.seek(c.startSecs)
            dismiss()
        } label: {
            HStack(spacing: Space.m) {
                ArtImage(url: c.img ?? art, px: 240, radius: Radius.xs)
                    .frame(width: 80, height: 45)
                    .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(Typo.rowTitle).foregroundStyle(on ? Palette.accentText : Palette.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let d = c.durationLabel, !d.isEmpty {
                        Text(d).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([c.title, c.durationLabel].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: episode page

struct EpisodeView: View {
    @Environment(AppModel.self) private var app
    let id: String
    @State private var episode: PodcastEpisode?
    @State private var notesExpanded = false
    @State private var failed = false
    @State private var attempt = 0
    @State private var allChapters = false

    var body: some View {
        let e = episode
        let isCurrent = app.player.now?.videoId == id
        let chapters = app.podcasts.chapters[id] ?? []
        EntityScaffold(title: e?.title ?? "", artURL: e?.thumbnail, isPlayingThis: isCurrent, onPlay: play) { off in
            header(off, isCurrent: isCurrent)
        } content: {
            VStack(alignment: .leading, spacing: Space.m) {
                if e == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                if e != nil { Text("Episode description").font(Typo.font(18, .bold)).padding(.top, Space.l) }
                if let d = e?.description {
                    Text(showNotes(d)).font(Typo.font(15)).foregroundStyle(Palette.subdued)
                        .tint(Palette.text)
                        .lineLimit(notesExpanded ? nil : 8)
                        .clipped()
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "encore-seek", let secs = Double(url.host ?? "") else { return .systemAction }
                            seek(secs)
                            return .handled
                        })
                    Button(notesExpanded ? "Show less" : "Show more") { withAnimation(Motion.quick) { notesExpanded.toggle() } }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                }
                if !chapters.isEmpty {
                    Text("Chapters").font(Typo.font(18, .bold)).padding(.top, Space.l).accessibilityAddTraits(.isHeader)
                    ChapterRows(chapters: allChapters ? chapters : Array(chapters.prefix(5)),
                                active: isCurrent ? chapterAt(chapters, app.player.position) : -1) { seek($0.startSecs) }
                        .accessibilityIdentifier("episode-chapters")
                    if chapters.count > 5 {
                        Button(allChapters ? "Show fewer chapters" : "Show all \(chapters.count) chapters") {
                            withAnimation(Motion.quick) { allChapters.toggle() }
                        }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    }
                }
                if let e, let showId = e.showId {
                    Button { app.router.push(.show(showId)) } label: {
                        Text("See all episodes").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                            .padding(.horizontal, 16).frame(height: 36).overlay(Capsule().stroke(Palette.dim))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, Space.l)
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .task(id: id) { await app.podcasts.loadChapters(id) }
        .task(id: "\(id)#\(attempt)") {
            do {
                episode = try await app.core.podcastEpisode(id: id)
                failed = false
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't load this episode")
                failed = true
            } catch {}
        }
    }

    private func header(_ offset: CGFloat, isCurrent: Bool) -> some View {
        let e = episode
        let saved = e.map { app.podcasts.isSaved($0) } ?? false
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .bottom, spacing: Space.m) {
                ArtImage(url: e?.thumbnail, px: 480, radius: Radius.l).frame(width: 120, height: 120)
                    .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
                Spacer()
            }
            .padding(.top, 112)
            Text(e?.title ?? " ").font(Typo.font(22, .bold)).lineLimit(4).accessibilityAddTraits(.isHeader)
            Button { if let s = e?.showId { app.router.push(.show(s)) } } label: {
                Text(e?.showTitle ?? " ").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
            }
            .buttonStyle(.plain)
            if let e { EpisodeMeta(episode: e) }
            HStack(spacing: Space.l + 4) {
                Button {
                    guard let e else { return }
                    let on = app.podcasts.toggleSaved(e)
                    Haptics.impact(.light)
                    app.showToast(on ? "Added to Your Episodes" : "Removed from Your Episodes")
                } label: {
                    IconSwap(name: saved ? "check-circle" : "plus-circle", fill: saved, size: 26).foregroundStyle(saved ? Palette.accent : Palette.subdued)
                }
                .accessibilityLabel(saved ? "Remove from Your Episodes" : "Add to Your Episodes")
                if let e { EpisodeDownloadButton(episode: e, size: 26) }
                Button { if let e { ShareSheet.present(.episode(e), app: app) } } label: { Icon(name: "export", size: 26) }
                    .accessibilityLabel("Share")
                Button { if let e { app.sheet = .episode(e) } } label: { Icon(name: "dots-three", size: 26) }
                    .accessibilityLabel("More options")
                Spacer()
                PlayCircleButton(playing: isCurrent && !app.player.paused, action: play).modifier(PlayAnchor())
                    .accessibilityIdentifier("entity-play")
            }
            .foregroundStyle(Palette.subdued)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.s)
    }

    private func play() { if let e = episode { playEpisodes(app, [e], at: 0) } }

    /// A tapped timestamp: seek if this episode plays, otherwise start it there.
    private func seek(_ secs: Double) {
        guard let e = episode else { return }
        playEpisodes(app, [e], at: 0, startSecs: secs)
    }
}

// MARK: Now Playing's "About this episode" (stream: pod-fixes)

/// Under the player, where a song has its lyrics card: the date · length line and the show notes
/// (5 lines, Show more), as the desktop's `EpisodeCard` and Spotify do.
struct EpisodeAboutCard: View {
    @Environment(AppModel.self) private var app
    @State private var episode: PodcastEpisode?
    @State private var expanded = false

    var body: some View {
        let id = app.player.current?.isEpisode == true ? app.player.current?.videoId : nil
        VStack(alignment: .leading, spacing: Space.s) {
            Text("About this episode").font(Typo.font(16, .bold))
            if let e = episode, e.id == id {
                EpisodeMeta(episode: e)
                if let d = e.description, !d.isEmpty {
                    Text(showNotes(d)).font(Typo.font(14)).foregroundStyle(Palette.subdued).tint(Palette.text)
                        .lineLimit(expanded ? nil : 5)
                    if d.count > 220 {
                        Button(expanded ? "Show less" : "Show more") { withAnimation(Motion.quick) { expanded.toggle() } }
                            .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    }
                }
            }
        }
        .foregroundStyle(Palette.text)
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.elevatedHighlight))
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("np-episode-about")
        .task(id: id) {
            expanded = false
            guard let id else { episode = nil; return }
            episode = try? await app.core.podcastEpisode(id: id)
        }
    }
}

// MARK: Your Episodes / New Episodes

enum EpisodeListKind { case saved, new }

struct EpisodeListView: View {
    @Environment(AppModel.self) private var app
    let kind: EpisodeListKind

    var body: some View {
        let eps = kind == .saved ? app.podcasts.saved : app.podcasts.newEpisodes
        let title = kind == .saved ? "Your Episodes" : "New Episodes"
        let tint = kind == .saved ? Palette.accentTile : Color(hex: "#7d4bb8")
        EntityScaffold(title: title, artURL: nil, fixedTint: tint, isPlayingThis: eps.contains { $0.id == app.player.now?.videoId },
                       onPlay: { playEpisodes(app, eps, at: 0) }) { off in
            EntityHeader(offset: off, cover: AnyView(EpisodeListTile(kind: kind, size: 240)), title: title,
                         meta: kind == .saved ? counted(eps.count, "episode") : "Episodes from the shows you follow",
                         actions: AnyView(EmptyView()), playing: eps.contains { $0.id == app.player.now?.videoId } && !app.player.paused,
                         onShuffle: {}, onPlay: { playEpisodes(app, eps, at: 0) })
        } content: {
            LazyVStack(spacing: 0) {
                if eps.isEmpty && !app.podcasts.listsLoaded {
                    if app.podcasts.listsFailed {
                        EntityLoadState(failed: true) { app.podcasts.listsFailed = false; Task { await app.podcasts.refresh() } }
                    } else {
                        SkeletonRows(count: 5)
                    }
                } else if eps.isEmpty {
                    VStack(spacing: Space.s) {
                        Text(kind == .saved ? "Add to Your Episodes" : "No new episodes").font(Typo.font(18, .bold))
                        Text(kind == .saved ? "Save episodes to listen to later. Tap + on any episode." : "Follow shows to see their newest episodes here.")
                            .font(Typo.meta).foregroundStyle(Palette.subdued).multilineTextAlignment(.center)
                    }
                    .padding(.top, 48).padding(.horizontal, Space.xxl)
                }
                ForEach(Array(eps.enumerated()), id: \.element.id) { i, e in
                    EpisodeRow(episode: e) { playEpisodes(app, eps, at: i) }
                }
            }
        }
        .task { await app.podcasts.refresh() }
    }
}

/// The Your Episodes (deep pink, bookmark) / New Episodes (purple, bell) tile.
struct EpisodeListTile: View {
    let kind: EpisodeListKind
    var size: CGFloat
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
            .fill(kind == .saved
                  ? LinearGradient(colors: [Palette.accentTileDeep, Palette.accentTile], startPoint: .bottomLeading, endPoint: .topTrailing)
                  : LinearGradient(colors: [Color(hex: "#5038a0"), Color(hex: "#a78bfa")], startPoint: .bottomLeading, endPoint: .topTrailing))
            .frame(width: size, height: size)
            .overlay(Icon(name: kind == .saved ? "bookmark-simple" : "bell", fill: true, size: size * 0.4).foregroundStyle(kind == .saved ? Palette.accent : .white))
    }
}

// MARK: speed sheet

struct SpeedSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    static let rates: [Double] = [0.5, 0.8, 1, 1.2, 1.5, 1.8, 2, 2.5, 3]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Playback speed").font(Typo.font(16, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.m)
            Divider().overlay(Palette.border)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Self.rates, id: \.self) { r in
                        let on = abs(app.settings.speed - r) < 0.01
                        Button {
                            Haptics.selection()
                            app.settings.setSpeed(r)
                            dismiss()
                        } label: {
                            HStack {
                                Text(speedLabel(r)).font(Typo.font(16, on ? .bold : .regular)).foregroundStyle(on ? Palette.accentText : Palette.text)
                                Spacer()
                                if on { Icon(name: "check", size: 20).foregroundStyle(Palette.accent) }
                            }
                            .padding(.horizontal, Space.gutter)
                            .frame(height: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.vertical, Space.s)
            }
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("speed-sheet")
    }
}

func speedLabel(_ r: Double) -> String {
    let s = r == r.rounded() ? String(Int(r)) : String(format: "%g", r)
    return "\(s)x"
}

// MARK: sheets

@MainActor func episodeSheetRows(_ app: AppModel, _ e: PodcastEpisode) -> [SheetRow] {
    let saved = app.podcasts.isSaved(e)
    let played = app.podcasts.progressOf(e).played
    var r: [SheetRow] = [
        SheetRow(icon: saved ? "check-circle" : "plus-circle", fill: saved, title: saved ? "Remove from Your Episodes" : "Add to Your Episodes",
                 tint: saved ? Palette.accent : Palette.text) {
            let on = app.podcasts.toggleSaved(e)
            app.showToast(on ? "Added to Your Episodes" : "Removed from Your Episodes")
        },
        SheetRow(icon: "check-circle", fill: played, title: played ? "Mark as unplayed" : "Mark as played") { app.podcasts.markPlayed(e, !played) },
        episodeDownloadRow(app, song: e.song, episode: e),
        SheetRow(icon: "queue", title: "Add to queue") { app.queue([e.song], from: e.showTitle) },
    ]
    if let s = e.showId {
        r.append(SheetRow(icon: "microphone", title: "Go to show") { app.router.nowPlayingOpen = false; app.router.push(.show(s)) })
    }
    r.append(SheetRow(icon: "share-network", title: "Share") { ShareSheet.presentAfterSheet(.episode(e), app: app) })
    return r
}

@MainActor func showSheetRows(_ app: AppModel, _ s: PodcastShow) -> [SheetRow] {
    let followed = app.podcasts.isFollowed(s.id)
    return [
        SheetRow(icon: followed ? "check-circle" : "plus-circle", fill: followed, title: followed ? "Unfollow" : "Follow",
                 tint: followed ? Palette.accent : Palette.text) {
            let on = app.podcasts.toggleFollow(s)
            app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
        },
        SheetRow(icon: "check-circle", title: "Mark all as played") {
            Task { if await app.podcasts.markAllPlayed(showId: s.id) { app.showToast("Marked all episodes as played") } }
        },
        SheetRow(icon: "share-network", title: "Share") { ShareSheet.presentAfterSheet(.show(s), app: app) },
    ]
}

// MARK: search ("Podcasts & Shows" chip)

struct PodcastSearchResultsView: View {
    @Environment(AppModel.self) private var app
    let query: String
    @State private var results: PodcastSearchResults?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if results == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                if let r = results, r.shows.isEmpty, r.episodes.isEmpty {
                    Text("No podcasts found for “\(query)”").font(Typo.font(16, .bold)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity).padding(.top, Space.xxl).padding(.horizontal, Space.gutter)
                }
                if let r = results, !r.shows.isEmpty {
                    Text("Podcasts").font(Typo.font(18, .bold)).padding(.horizontal, Space.gutter).padding(.vertical, Space.s)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: Space.l) {
                            ForEach(r.shows.prefix(10)) { s in
                                Button { app.router.push(.show(s.id)) } label: {
                                    MediaCard(title: s.title, subtitle: s.author, thumbnail: s.thumbnail, size: Metrics.cardSmall)
                                }
                                .buttonStyle(PressScale())
                                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                    Haptics.impact(.medium); app.sheet = .show(s)
                                })
                                .accessibilityIdentifier("show-card")
                            }
                        }
                        .padding(.horizontal, Space.gutter)
                    }
                }
                if let r = results, !r.episodes.isEmpty {
                    Text("Episodes").font(Typo.font(18, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.l)
                    ForEach(Array(r.episodes.enumerated()), id: \.element.id) { i, e in
                        EpisodeRow(episode: e, showDescription: false) { playEpisodes(app, r.episodes, at: i) }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .task(id: "\(query)#\(attempt)") {
            // Debounced: the directories rate-limit (podcasts.md).
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                results = try await app.core.podcastSearch(query: query)
                failed = false
            } catch let error where !FriendlyError.isCancellation(error) {
                _ = friendlyError(error, "Couldn't search podcasts")
                results = nil
                failed = true
            } catch {}
        }
    }
}
