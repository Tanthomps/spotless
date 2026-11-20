// Stream ios-p2: Recents (Spotify iOS: profile menu › Recents) and your listening stats.
// "Recently played" is the desktop's page: the contexts you played from as a card grid
// (`recent_play_contexts`), then the local listening history (`lib_recent_tracks`), newest first
// under day headers; "Your top" is the last four weeks (`listening_stats`): time listened, plays, top artists
// and top songs (Spotify's profile "Top artists / tracks this month"). Desktop: `/history` and
// `/stats` (iOS: StatsView, linked from "Your top"). Nothing here leaves the phone; Settings ›
// Privacy clears it.
import SwiftUI

struct HistoryView: View {
    @Environment(AppModel.self) private var app
    enum Tab: String, CaseIterable { case recents = "Recently played", top = "Your top" }
    @State var tab: Tab = .recents
    @State private var rows: [RecentTrack]?
    /// The albums, playlists and artists you played from (the desktop's card grid on top).
    @State private var contexts: [RecentPlayContext] = []
    @State private var showAllContexts = false
    @State private var stats: ListeningStats?
    /// Each tab fails on its own: a failed Your top doesn't hide Recents that loaded.
    @State private var rowsFailed = false
    @State private var statsFailed = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack { BackButton(); Spacer() }
                    .padding(.horizontal, Space.s + 2).frame(height: 44)
                Text("Recents").font(Typo.pageTitle).padding(.horizontal, Space.gutter).padding(.top, Space.s)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: Space.s) {
                    ForEach(Tab.allCases, id: \.self) { t in
                        Chip(title: t.rawValue, selected: tab == t) { withAnimation(Motion.quick) { tab = t } }
                            .accessibilityIdentifier("history-chip-\(t == .recents ? "recents" : "top")")
                    }
                }
                .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
                switch tab {
                case .recents: recents
                case .top: top
                }
            }
            .padding(.bottom, Space.xl)
        }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        // One load at a time: a newer play cancels the one in flight instead of racing it.
        .task(id: app.homeSerial) { await load() }
        .refreshable { await load() }
    }

    private static let context = PlayContext(kind: .song, id: nil, title: "Recents")

    // MARK: recently played

    @ViewBuilder private var recents: some View {
        if let rows {
            if rows.isEmpty && contexts.isEmpty {
                EntityEmptyState(icon: "clock-counter-clockwise", title: "Nothing played yet",
                                 line: "Albums, playlists, artists and songs you play will show up here.",
                                 action: "Find something to play") { app.router.select(.search) }
                    .accessibilityIdentifier("history-empty")
            } else {
                if !contexts.isEmpty { contextGrid }
                if !rows.isEmpty {
                    Text("Songs").font(Typo.font(20, .bold))
                        .padding(.horizontal, Space.gutter).padding(.top, Space.xl)
                        .accessibilityAddTraits(.isHeader)
                }
                let songs = rows.map(\.song)
                ForEach(Self.days(rows), id: \.title) { day in
                    Text(day.title).font(Typo.font(16, .bold))
                        .padding(.horizontal, Space.gutter).padding(.top, Space.l).padding(.bottom, Space.xs)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(day.indices, id: \.self) { i in
                        TrackRow(song: songs[i], context: Self.context) { app.player.play(songs, at: i, context: Self.context) }
                    }
                }
            }
        } else {
            EntityLoadState(failed: rowsFailed) { Task { await load() } }
        }
    }

    /// Two columns of the contexts you played from; six until "Show all" (the desktop's two rows).
    private var contextGrid: some View {
        let shown = showAllContexts ? contexts : Array(contexts.prefix(6))
        return VStack(alignment: .leading, spacing: Space.m) {
            GeometryReader { g in
                let w = floor((g.size.width - Space.gutter * 2 - Space.l) / 2)
                LazyVGrid(columns: [GridItem(.fixed(w), spacing: Space.l, alignment: .top), GridItem(.fixed(w), alignment: .top)],
                          alignment: .leading, spacing: Space.l) {
                    ForEach(shown, id: \.self) { c in
                        Button { open(c) } label: {
                            MediaCard(title: c.title, subtitle: Self.subtitle(c), thumbnail: c.thumbnail, circle: c.kind == "artist",
                                      size: w, liked: c.kind == "liked")
                        }
                        .buttonStyle(PressScale())
                        .accessibilityIdentifier("history-context")
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            .frame(height: Self.gridHeight(count: shown.count))
            if contexts.count > 6 && !showAllContexts {
                Button("Show all") { withAnimation(Motion.quick) { showAllContexts = true } }
                    .font(Typo.metaBold).foregroundStyle(Palette.subdued)
                    .padding(.horizontal, Space.gutter)
                    .accessibilityIdentifier("history-contexts-all")
            }
        }
    }

    /// The grid's height: cards are about half the screen wide plus two lines of text.
    private static func gridHeight(count: Int) -> CGFloat {
        let w = floor((UIScreen.main.bounds.width - Space.gutter * 2 - Space.l) / 2)
        let rows = CGFloat((count + 1) / 2)
        return rows * (w + 56) + max(0, rows - 1) * Space.l
    }

    /// The card's second line (the desktop's `subtitleFor`).
    static func subtitle(_ c: RecentPlayContext) -> String {
        switch c.kind {
        case "liked": return "Playlist • You"
        case "artist": return "Artist"
        case "podcast": return "Podcast" + (c.subtitle.map { " • \($0)" } ?? "")
        case "playlist":
            let creator = creatorOf(c.subtitle)
            return creator.isEmpty ? "Playlist" : "Playlist • \(creator)"
        default:
            if let s = c.subtitle, !s.isEmpty { return s }
            return c.kind == "album" ? "Album" : c.kind == "radio" || c.kind == "mix" ? "Radio" : "Playlist"
        }
    }

    /// A context's page; radios and mixes open their radio page.
    private func open(_ c: RecentPlayContext) {
        switch c.kind {
        case "liked": app.router.push(.liked)
        case "album": app.router.push(.album(c.id))
        case "artist": app.router.push(.artist(c.id))
        case "podcast": app.router.push(.show(c.id))
        case "audiobook": app.router.push(.audiobook(c.id))
        case "daily_mix": app.router.push(.dailyMix(c.id, c.title, c.subtitle, c.thumbnail))
        case "radio": app.router.push(.radio(c.params ?? "song", c.id, c.title))
        case "mix": app.router.push(.radio("artist", c.id, c.title))
        default: app.router.push(c.id == "EPISODES" ? .yourEpisodes : c.id == likedPlaylistId ? .liked : .playlist(c.id))
        }
    }

    /// Rows grouped under "Today", "Yesterday", then the date (indices into `rows`, in order).
    static func days(_ rows: [RecentTrack], now: Date = .now, calendar: Calendar = .current) -> [(title: String, indices: [Int])] {
        var out: [(title: String, indices: [Int])] = []
        let fmt = DateFormatter()
        fmt.calendar = calendar
        fmt.setLocalizedDateFormatFromTemplate("EEEMMMd")
        for (i, r) in rows.enumerated() {
            let d = Date(timeIntervalSince1970: TimeInterval(r.playedAt))
            let title: String
            if calendar.isDate(d, inSameDayAs: now) { title = "Today" }
            else if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(d, inSameDayAs: y) { title = "Yesterday" }
            else { title = fmt.string(from: d) }
            if out.last?.title == title { out[out.count - 1].indices.append(i) } else { out.append((title, [i])) }
        }
        return out
    }

    // MARK: your top

    @ViewBuilder private var top: some View {
        if let stats {
            if stats.plays == 0 {
                empty("Listen for a while and your top artists and songs show up here.")
            } else {
                Text("Last 4 weeks").font(Typo.font(13)).foregroundStyle(Palette.subdued).padding(.horizontal, Space.gutter)
                statsLink
                HStack(spacing: Space.s) {
                    tile(Self.minutes(stats.secs), "minutes listened")
                    tile("\(stats.plays)", stats.plays == 1 ? "play" : "plays")
                    tile("\(stats.artists)", stats.artists == 1 ? "artist" : "artists")
                }
                .padding(.horizontal, Space.gutter).padding(.top, Space.s)
                if !stats.topArtists.isEmpty {
                    header("Top artists")
                    ForEach(Array(stats.topArtists.prefix(10).enumerated()), id: \.offset) { i, a in artistRow(i + 1, a) }
                }
                if !stats.topSongs.isEmpty {
                    header("Top songs")
                    let songs = stats.topSongs.prefix(10).map(\.song)
                    ForEach(Array(songs.enumerated()), id: \.offset) { i, s in
                        TrackRow(song: s, index: i + 1, context: Self.context) { app.player.play(Array(songs), at: i, context: Self.context) }
                    }
                }
            }
        } else {
            EntityLoadState(failed: statsFailed) { Task { await load() } }
        }
    }

    /// The full stats page: other ranges, top albums and when you listen.
    private var statsLink: some View {
        Button { app.router.push(.stats) } label: {
            HStack(spacing: Space.m) {
                Icon(name: "chart-bar", size: 22).foregroundStyle(Palette.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Listening stats").font(Typo.font(15, .bold))
                    Text("Top tracks and albums, any range, and when you listen").font(Typo.font(12)).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
                Icon(name: "caret-right", size: 16).foregroundStyle(Palette.subdued)
            }
            .padding(Space.m)
            .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.highlight))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 0.98))
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
        .accessibilityIdentifier("history-stats-link")
    }

    /// "1,234" minutes (rounded down, at least 1 once anything played).
    static func minutes(_ secs: Int) -> String {
        let m = secs > 0 ? max(1, secs / 60) : 0
        return m.formatted(.number)
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typo.font(22, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(Typo.font(12)).foregroundStyle(Palette.subdued).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.s, style: .continuous).fill(Palette.highlight))
        .accessibilityElement(children: .combine)
    }

    private func header(_ title: String) -> some View {
        Text(title).font(Typo.font(20, .bold))
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.s)
            .accessibilityAddTraits(.isHeader)
    }

    private func artistRow(_ rank: Int, _ a: TopArtist) -> some View {
        Button {
            if let id = a.id { app.router.push(.artist(id)) }
        } label: {
            HStack(spacing: Space.m) {
                Text("\(rank)").font(Typo.font(16)).foregroundStyle(Palette.subdued).frame(width: 24)
                if let t = a.thumbnail { ArtImage(url: t, px: 144, circle: true).frame(width: 48, height: 48) }
                else { AccountPhoto(url: nil, name: a.name, size: 48) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(a.name).font(Typo.rowTitle).lineLimit(1)
                    Text("\(a.plays) play\(a.plays == 1 ? "" : "s")").font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                }
                Spacer()
            }
            .padding(.horizontal, Space.gutter).frame(height: Metrics.rowHeight).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .disabled(a.id == nil)
        .accessibilityIdentifier("top-artist")
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Typo.font(14)).foregroundStyle(Palette.subdued)
            .padding(.horizontal, Space.gutter).padding(.top, Space.l)
            .accessibilityIdentifier("history-empty")
    }

    private func load() async {
        rowsFailed = false; statsFailed = false
        async let r = app.core.recentTracks(limit: 200)
        async let c = app.core.recentPlayContexts(limit: 50)
        async let s = app.core.listeningStats(since: Int64(Date().timeIntervalSince1970) - 28 * 86_400)
        contexts = (try? await c) ?? contexts
        do { rows = try await r } catch { if rows == nil && !FriendlyError.isCancellation(error) { rowsFailed = true } }
        do { stats = try await s } catch { if stats == nil && !FriendlyError.isCancellation(error) { statsFailed = true } }
    }
}
