// Listening stats (the desktop's /stats, ui/src/routes/stats/+page.svelte): range chips, the
// headline numbers, Top artists / tracks / albums, then the activity charts. The core counts
// (`listening_stats {since}`); this page owns the calendar it draws against, as the desktop's
// `ui/src/lib/stats.ts` does (StatsMath below is that file in Swift). Everything stays on the phone.
// Reached from the side menu ("Listening stats"), Recents › Your top, and `encore://stats`.
import Charts
import SwiftUI

enum StatsRange: String, CaseIterable {
    case week, month, year, all
    var label: String {
        switch self { case .week: "Last 7 days"; case .month: "Last 30 days"; case .year: "Last 12 months"; case .all: "All time" }
    }
    var phrase: String {
        switch self { case .week: "this week"; case .month: "this month"; case .year: "this year"; case .all: "of all time" }
    }
}

struct StatsView: View {
    @Environment(AppModel.self) private var app
    /// Kept for the session: whoever checks the month comes back to the month.
    private static var lastRange: StatsRange = .month
    @State private var range: StatsRange = StatsView.lastRange
    @State private var shown: StatsRange = StatsView.lastRange
    @State private var stats: ListeningStats?
    @State private var failed = false
    @State private var allTracks = false
    /// Artist photos (their page's avatar), asked once per visit.
    @State private var photos: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                HStack { BackButton(); Spacer() }
                    .padding(.horizontal, Space.s + 2).frame(height: 44)
                header
                chips
                content
            }
            .padding(.bottom, Space.xl)
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Color(hex: "#1e3264"), Palette.base], startPoint: .top, endPoint: .bottom)
                .frame(height: 320).ignoresSafeArea()
        }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        // A song's time is settled when the next one starts: refresh on each new song and range switch.
        .task(id: "\(range.rawValue)#\(app.player.now?.videoId ?? "")") { await load(range) }
        .refreshable { await load(range) }
        .accessibilityIdentifier("stats-page")
    }

    // MARK: header

    /// The top artist's picture (round), else the top song's cover.
    private var artistImage: String? {
        stats?.topArtists.first.flatMap { a in a.id.flatMap { photos[$0] } ?? a.thumbnail }
    }
    private var headerImage: String? { artistImage ?? stats?.topSongs.first?.song.thumbnail }

    private var header: some View {
        HStack(alignment: .bottom, spacing: Space.l) {
            Group {
                if let img = headerImage {
                    ArtImage(url: img, px: 360, radius: Radius.s, circle: artistImage != nil)
                } else {
                    Circle().fill(Palette.elevatedHighlight)
                        .overlay(Icon(name: "chart-bar", size: 44).foregroundStyle(Palette.subdued))
                }
            }
            .frame(width: 112, height: 112)
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Listening stats").font(Typo.font(28, .bold)).lineLimit(2).minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                if let s = stats, s.firstAt != nil {
                    Text("\(StatsMath.listened(s.secs)) • \(s.plays.formatted()) plays")
                        .font(Typo.font(13)).foregroundStyle(Palette.meta).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.s)
    }

    private var chips: some View {
        HStack(spacing: Space.m) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(StatsRange.allCases, id: \.self) { r in
                        Chip(title: r.label, selected: range == r) {
                            range = r; Self.lastRange = r
                        }
                        .accessibilityIdentifier("stats-range-\(r.rawValue)")
                    }
                }
                .padding(.leading, Space.gutter)
            }
            if !(stats?.topSongs.isEmpty ?? true) {
                PlayCircleButton(playing: playingTop && !app.player.paused) { playTop() }
                    .accessibilityLabel("Play your top tracks")
                    .padding(.trailing, Space.gutter)
            }
        }
        .padding(.vertical, Space.l)
    }

    // MARK: body

    @ViewBuilder private var content: some View {
        if let s = stats {
            if s.firstAt == nil {
                VStack(spacing: Space.s) {
                    Icon(name: "chart-bar", size: 48).foregroundStyle(Palette.subdued)
                    Text("Your stats will appear here").font(Typo.font(18, .bold))
                    Text("Play some music and we'll count your top artists, tracks and listening time. Everything stays on this iPhone.")
                        .font(Typo.font(14)).foregroundStyle(Palette.subdued).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.horizontal, Space.xxl).padding(.top, Space.xxl)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stats-empty")
            } else {
                filled(s)
            }
        } else {
            EntityLoadState(failed: failed) { Task { await load(range) } }
        }
    }

    @ViewBuilder private func filled(_ s: ListeningStats) -> some View {
        let delta = StatsMath.change(s.secs, s.prevSecs)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
            tile(StatsMath.listened(s.secs), "Listening time",
                 hint: delta.flatMap { shown == .all ? nil : "\($0 > 0 ? "+" : "")\($0)%" })
            tile(s.plays.formatted(), "Plays")
            tile(s.songs.formatted(), "Songs", hint: shown != .all && s.newSongs > 0 ? "\(s.newSongs.formatted()) new" : nil)
            tile("\(s.streak.formatted()) day\(s.streak == 1 ? "" : "s")", "Streak",
                 hint: (s.bestStreak ?? 0) > s.streak ? "best \((s.bestStreak ?? 0).formatted())" : nil)
        }
        .padding(.horizontal, Space.gutter)
        if s.plays == 0 {
            Text("Nothing played in this period. Try a longer range.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                .padding(.horizontal, Space.gutter).padding(.top, Space.l)
        }
        if !s.topArtists.isEmpty {
            sectionHeader("Top artists \(shown.phrase)", note: "Only visible to you")
            artistShelf(s.topArtists)
        }
        if !s.topSongs.isEmpty {
            HStack(alignment: .lastTextBaseline) {
                sectionHeader("Top tracks \(shown.phrase)", note: "Only visible to you")
                Spacer()
                if s.topSongs.count > 4 {
                    Button(allTracks ? "Show less" : "Show all") { withAnimation(Motion.quick) { allTracks.toggle() } }
                        .font(Typo.metaBold).foregroundStyle(Palette.subdued)
                        .padding(.trailing, Space.gutter).padding(.bottom, Space.s)
                        .accessibilityIdentifier("stats-tracks-toggle")
                }
            }
            let songs = topSongs(s)
            ForEach(Array(songs.prefix(allTracks ? songs.count : 4).enumerated()), id: \.offset) { i, song in
                TrackRow(song: song, index: i + 1, showPlays: true, context: context) { playTop(at: i) }
                    .transition(Motion.reveal)
            }
        }
        if !s.topAlbums.isEmpty {
            sectionHeader("Top albums \(shown.phrase)")
            CardShelf(items: s.topAlbums.map {
                BrowseItem(kind: .album, id: $0.id, title: $0.title,
                           subtitle: [$0.artist, StatsMath.listened($0.secs)].filter { !$0.isEmpty }.joined(separator: " • "),
                           thumbnail: $0.thumbnail)
            })
        }
        if let pods = s.topPodcasts, !pods.isEmpty {
            let n = s.episodes ?? 0
            sectionHeader("Top podcasts \(shown.phrase)",
                          note: "\(StatsMath.listened(s.podcastSecs ?? 0)) • \(n.formatted()) episode\(n == 1 ? "" : "s")")
            CardShelf(items: pods.map {
                BrowseItem(kind: .podcast, id: $0.id ?? "", title: $0.name,
                           subtitle: "\(StatsMath.listened($0.secs)) • \($0.plays.formatted()) play\($0.plays == 1 ? "" : "s")",
                           thumbnail: $0.thumbnail)
            })
            .accessibilityIdentifier("stats-podcasts")
        }
        if s.plays > 0 {
            StatsActivity(stats: s, range: shown)
        }
        footer(s)
    }

    private func tile(_ value: String, _ label: String, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Typo.font(20, .bold)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
            HStack(spacing: 0) {
                Text(label).foregroundStyle(Palette.subdued)
                if let hint { Text(" • \(hint)").foregroundStyle(Palette.meta) }
            }
            .font(Typo.font(12)).lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.m)
        .background(RoundedRectangle(cornerRadius: Radius.l, style: .continuous).fill(Palette.highlight))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats-tile")
    }

    private func sectionHeader(_ title: String, note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.font(20, .bold)).lineLimit(1).minimumScaleFactor(0.8).accessibilityAddTraits(.isHeader)
            if let note { Text(note).font(Typo.font(13)).foregroundStyle(Palette.subdued) }
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.m)
    }

    private func artistShelf(_ artists: [TopArtist]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Space.l) {
                ForEach(artists, id: \.self) { a in
                    Button { if let id = a.id { app.router.push(.artist(id)) } } label: {
                        MediaCard(title: a.name, subtitle: "\(a.plays.formatted()) play\(a.plays == 1 ? "" : "s")",
                                  thumbnail: a.id.flatMap { photos[$0] } ?? a.thumbnail, circle: true, size: 136)
                    }
                    .buttonStyle(PressScale())
                    .disabled(a.id == nil)
                    .accessibilityIdentifier("stats-artist")
                }
            }
            .padding(.horizontal, Space.gutter)
        }
    }

    private func footer(_ s: ListeningStats) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Divider().overlay(Palette.border)
            Text("Counted on this iPhone only\(s.firstAt.map { " since " + Date(timeIntervalSince1970: TimeInterval($0)).formatted(date: .long, time: .omitted) } ?? "").")
                .font(Typo.font(13)).foregroundStyle(Palette.subdued)
            Button(action: clearHistory) {
                Text("Clear listening history").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.l).frame(height: 36)
                    .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("stats-clear-history")
        }
        .padding(.horizontal, Space.gutter).padding(.top, Space.xxl)
    }

    // MARK: actions

    /// Our own play count in the subtitle, as the desktop's Plays column.
    private func topSongs(_ s: ListeningStats) -> [SongItem] {
        s.topSongs.map { t in var song = t.song; song.playCount = "\(t.plays.formatted()) play\(t.plays == 1 ? "" : "s")"; return song }
    }

    private var context: PlayContext { PlayContext(kind: .song, id: nil, title: "Top tracks \(shown.phrase)") }
    private var playingTop: Bool { app.player.hasTrack && app.player.queue.sourceName == context.title }

    private func playTop(at i: Int = 0) {
        guard let s = stats, !s.topSongs.isEmpty else { return }
        if playingTop && i == 0 { app.player.togglePause(); return }
        app.player.play(topSongs(s), at: i, context: context)
    }

    private func clearHistory() {
        app.confirm = ConfirmRequest(title: "Clear listening history?",
                                     message: "This forgets every play counted on this iPhone. Your stats, Your Rotation and recommendations start over. This can't be undone.",
                                     action: "Clear") {
            Task {
                do {
                    try await app.core.clearListeningHistory()
                    app.homeSerial += 1
                    app.showToast("Listening history cleared")
                    await load(range)
                } catch { app.showToast("Couldn't clear your listening history") }
            }
        }
    }

    private func load(_ r: StatsRange) async {
        do {
            let s = try await app.core.listeningStats(since: StatsMath.rangeStart(r))
            guard !Task.isCancelled else { return }
            stats = s; shown = r; failed = false
            await loadPhotos(s.topArtists)
        } catch where !FriendlyError.isCancellation(error) {
            if stats == nil { failed = true } else {
                // The chip goes back to the range still on screen, and says why.
                range = shown
                app.fail(friendlyError(error, "Couldn't load \(r.phrase)"))
            }
        } catch {}
    }

    private func loadPhotos(_ artists: [TopArtist]) async {
        for a in artists {
            guard let id = a.id, id.hasPrefix("UC"), photos[id] == nil else { continue }
            if let p = try? await app.core.getArtist(id: id), let t = p.thumbnail { photos[id] = t }
        }
    }
}

// MARK: activity charts

/// "Activity" (a bar per day, or per month for a year) and "When you listen" (the four parts of
/// the day as a donut, and the week's hours as a heatmap).
struct StatsActivity: View {
    let stats: ListeningStats
    let range: StatsRange
    var now = Date()

    var body: some View {
        let bars = StatsMath.bars(stats.days, range, now: now)
        let monthly = bars.first?.key.count == 7
        let average = bars.isEmpty ? 0 : stats.secs / bars.count
        let peak = bars.max { $0.secs < $1.secs }.flatMap { $0.secs > 0 ? $0 : nil }
        VStack(alignment: .leading, spacing: 0) {
            title("Activity")
            Text(summary(monthly: monthly, average: average, peak: peak))
                .font(Typo.font(13)).foregroundStyle(Palette.subdued).padding(.bottom, Space.l)
            Chart(bars, id: \.key) { b in
                BarMark(x: .value("Day", b.date, unit: monthly ? .month : .day), y: .value("Minutes", Double(b.secs) / 60))
                    .foregroundStyle(b.key == peak?.key ? Palette.accent : Palette.accent.opacity(0.45))
                    .cornerRadius(2)
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine().foregroundStyle(Palette.border)
                    AxisValueLabel { if let m = v.as(Double.self) { Text(StatsMath.listened(Int(m * 60))) } }
                        .foregroundStyle(Palette.subdued).font(Typo.font(10))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: monthly ? 6 : 5)) { _ in
                    AxisValueLabel(format: monthly ? .dateTime.month(.abbreviated) : .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Palette.subdued).font(Typo.font(10))
                }
            }
            .frame(height: 160)
            .accessibilityLabel("Listening time per \(monthly ? "month" : "day")")
            .accessibilityIdentifier("stats-activity-chart")

            title("When you listen").padding(.top, Space.xl)
            if let b = StatsMath.busiest(stats.hours) {
                Text("Mostly on \(StatsMath.weekdayName(b.day))s, around \(StatsMath.hourName(b.hour))")
                    .font(Typo.font(13)).foregroundStyle(Palette.subdued).padding(.bottom, Space.l)
            }
            StatsDayparts(hours: stats.hours).padding(.bottom, Space.xl)
            StatsHeatmap(hours: stats.hours)
        }
        .padding(.horizontal, Space.gutter)
    }

    private func title(_ t: String) -> some View {
        Text(t).font(Typo.font(20, .bold)).padding(.top, Space.xl).padding(.bottom, Space.xs).accessibilityAddTraits(.isHeader)
    }

    private func summary(monthly: Bool, average: Int, peak: StatsMath.Bar?) -> String {
        var s = "\(monthly ? "Monthly" : "Daily") average \(StatsMath.listened(average))"
        if let peak {
            let when = monthly ? peak.date.formatted(.dateTime.month(.wide).year()) : peak.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            s += " • busiest \(monthly ? "month" : "day") \(when) (\(StatsMath.listened(peak.secs)))"
        }
        return s
    }
}

/// Morning, afternoon, evening and night as a donut: the part with the most listening named in
/// its middle, each part's share beside it.
struct StatsDayparts: View {
    let hours: [Int]

    /// Four shades of the accent: light at dawn, the accent itself in the afternoon, darkest at night.
    static func color(_ p: StatsMath.Daypart) -> Color {
        switch p {
        case .morning: Color(hex: "#ffa3c4")
        case .afternoon: Palette.accent
        case .evening: Color(hex: "#b81f58")
        case .night: Color(hex: "#6e1238")
        }
    }

    var body: some View {
        let secs = StatsMath.dayparts(hours)
        let total = max(1, secs.values.reduce(0, +))
        let top = StatsMath.Daypart.allCases.max { (secs[$0] ?? 0) < (secs[$1] ?? 0) } ?? .evening
        let share = { (p: StatsMath.Daypart) in Double(secs[p] ?? 0) / Double(total) }
        HStack(spacing: Space.xl) {
            Chart(StatsMath.Daypart.allCases, id: \.self) { p in
                SectorMark(angle: .value("Seconds", secs[p] ?? 0), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(4)
                    .foregroundStyle(Self.color(p))
            }
            .chartBackground { _ in
                VStack(spacing: 0) {
                    Text(share(top).formatted(.percent.precision(.fractionLength(0)))).font(Typo.font(22, .bold))
                    Text(top.title).font(Typo.font(12)).foregroundStyle(Palette.subdued)
                }
            }
            .frame(width: 136, height: 136)
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(StatsMath.Daypart.allCases, id: \.self) { p in
                    HStack(spacing: Space.s) {
                        RoundedRectangle(cornerRadius: 3).fill(Self.color(p)).frame(width: 10, height: 10)
                        Text(p.title).font(Typo.font(13)).foregroundStyle(Palette.subdued)
                        Spacer(minLength: Space.s)
                        Text(share(p).formatted(.percent.precision(.fractionLength(0)))).font(Typo.font(13, .bold)).monospacedDigit()
                    }
                }
            }
        }
        .padding(Space.l)
        .background(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous).fill(Palette.highlight))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("stats-dayparts")
    }
}

/// A week of hours, one cell per weekday and hour, shaded by how much was heard then. Rows run
/// Monday to Sunday.
struct StatsHeatmap: View {
    let hours: [Int]
    private static let rows = [1, 2, 3, 4, 5, 6, 0]
    private static let shades: [Color] = [Color.white.opacity(0.06), Palette.accent.opacity(0.25), Palette.accent.opacity(0.5),
                                          Palette.accent.opacity(0.75), Palette.accent]

    var body: some View {
        let maxSecs = hours.max() ?? 0
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Self.rows, id: \.self) { d in
                HStack(spacing: 2) {
                    Text(StatsMath.weekdayName(d, short: true)).font(Typo.font(10)).foregroundStyle(Palette.subdued)
                        .frame(width: 28, alignment: .leading)
                    ForEach(0..<24, id: \.self) { h in
                        let secs = hours.indices.contains(d * 24 + h) ? hours[d * 24 + h] : 0
                        RoundedRectangle(cornerRadius: 2).fill(Self.shades[StatsMath.heat(secs, maxSecs)])
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            HStack(spacing: 0) {
                Color.clear.frame(width: 30, height: 1)
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(StatsMath.hourName(h)).font(Typo.font(10)).foregroundStyle(Palette.subdued)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 2)
            HStack(spacing: 4) {
                Spacer()
                Text("Less")
                ForEach(0..<5, id: \.self) { i in RoundedRectangle(cornerRadius: 2).fill(Self.shades[i]).frame(width: 10, height: 10) }
                Text("More")
            }
            .font(Typo.font(10)).foregroundStyle(Palette.subdued).padding(.top, Space.s)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Listening by weekday and hour")
        .accessibilityIdentifier("stats-heatmap")
    }
}

// MARK: the calendar (ui/src/lib/stats.ts)

enum StatsMath {
    /// Where a range starts, unix secs, local time: the last 7 or 30 days counting today, the last
    /// 12 months counting this one, or everything (0). Always runs to now.
    static func rangeStart(_ r: StatsRange, now: Date = Date(), calendar cal: Calendar = .current) -> Int64 {
        let today = cal.startOfDay(for: now)
        let start: Date?
        switch r {
        case .week: start = cal.date(byAdding: .day, value: -6, to: today)
        case .month: start = cal.date(byAdding: .day, value: -29, to: today)
        case .year:
            let month = cal.date(from: cal.dateComponents([.year, .month], from: today))!
            start = cal.date(byAdding: .month, value: -11, to: month)
        case .all: start = nil
        }
        return start.map { Int64($0.timeIntervalSince1970) } ?? 0
    }

    struct Bar: Hashable {
        /// `2026-10-17`, or `2026-10` for a month.
        var key: String
        /// Its first moment, local.
        var date: Date
        var secs: Int
    }

    /// All time draws days until the history is about three months long, months after that.
    static let dailyUpTo = 92

    /// One bar per day of the window, or per month for a year and a long all time, with nothing
    /// left out: a day without a play is a bar of zero. `days` holds only the days that had something.
    static func bars(_ days: [CorePair<String, Int>], _ range: StatsRange, now: Date = Date(), calendar cal: Calendar = .current) -> [Bar] {
        let first: Date
        if range == .all {
            first = days.first.flatMap { dayDate($0.first, cal) } ?? now
        } else {
            first = Date(timeIntervalSince1970: TimeInterval(rangeStart(range, now: now, calendar: cal)))
        }
        let monthly = range == .year || (range == .all && now.timeIntervalSince(first) / 86_400 > Double(dailyUpTo))
        var secs: [String: Int] = [:]
        for d in days { secs[monthly ? String(d.first.prefix(7)) : d.first, default: 0] += d.second }
        var out: [Bar] = []
        var at = monthly ? cal.date(from: cal.dateComponents([.year, .month], from: first))! : cal.startOfDay(for: first)
        while at <= now {
            let c = cal.dateComponents([.year, .month, .day], from: at)
            let key = monthly ? String(format: "%04d-%02d", c.year!, c.month!) : String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            out.append(Bar(key: key, date: at, secs: secs[key] ?? 0))
            at = cal.date(byAdding: monthly ? .month : .day, value: 1, to: at)!
        }
        return out
    }

    private static func dayDate(_ key: String, _ cal: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return cal.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    /// "4 hr 12 min", "35 min", "0 min": rounded to the minute.
    static func listened(_ secs: Int) -> String {
        let mins = Int((Double(secs) / 60).rounded())
        let (h, m) = (mins / 60, mins % 60)
        let unit = { (v: Int, u: UnitDuration) in Measurement(value: Double(v), unit: u).formatted(.measurement(width: .abbreviated)) }
        if h == 0 { return unit(m, .minutes) }
        return m == 0 ? unit(h, .hours) : "\(unit(h, .hours)) \(unit(m, .minutes))"
    }

    /// Percent change against the window before, or nil when there's nothing before to compare.
    static func change(_ secs: Int, _ prev: Int?) -> Int? {
        guard let prev, prev > 0 else { return nil }
        return Int((Double(secs - prev) / Double(prev) * 100).rounded())
    }

    /// The weekday (0 = Sunday) and the hour that hold the most listening, each summed on its own,
    /// so one long Friday night doesn't decide both. Nil with nothing heard.
    static func busiest(_ hours: [Int]) -> (day: Int, hour: Int)? {
        let at = { (i: Int) in hours.indices.contains(i) ? hours[i] : 0 }
        let days = (0..<7).map { d in (0..<24).reduce(0) { $0 + at(d * 24 + $1) } }
        let byHour = (0..<24).map { h in (0..<7).reduce(0) { $0 + at($1 * 24 + h) } }
        guard days.contains(where: { $0 > 0 }) else { return nil }
        let top = { (xs: [Int]) in xs.firstIndex(of: xs.max()!)! }
        return (top(days), top(byHour))
    }

    /// 0 for nothing, else 1-4 by the cell's share of the busiest one: the heatmap's five shades.
    static func heat(_ secs: Int, _ max: Int) -> Int {
        secs <= 0 || max <= 0 ? 0 : min(4, Int((Double(secs) / Double(max) * 4).rounded(.up)))
    }

    enum Daypart: CaseIterable {
        case morning, afternoon, evening, night
        var title: String {
            switch self { case .morning: "Morning"; case .afternoon: "Afternoon"; case .evening: "Evening"; case .night: "Night" }
        }
        /// The part a local hour falls in. Night runs past midnight.
        static func of(hour h: Int) -> Daypart {
            switch h { case 5..<12: .morning; case 12..<17: .afternoon; case 17..<22: .evening; default: .night }
        }
    }

    /// The week's `hours` folded into seconds per part of the day.
    static func dayparts(_ hours: [Int]) -> [Daypart: Int] {
        var out: [Daypart: Int] = [.morning: 0, .afternoon: 0, .evening: 0, .night: 0]
        for (i, s) in hours.enumerated() { out[Daypart.of(hour: i % 24), default: 0] += s }
        return out
    }

    /// Weekday `d` (0 = Sunday): "Friday", or "Fri".
    static func weekdayName(_ d: Int, short: Bool = false) -> String {
        let cal = Calendar.current
        let names = short ? cal.shortWeekdaySymbols : cal.weekdaySymbols
        return names[(d % 7 + 7) % 7]
    }

    /// "9 PM" (or the locale's "21").
    static func hourName(_ h: Int) -> String {
        let d = Calendar.current.date(from: DateComponents(year: 2026, month: 1, day: 4, hour: h)) ?? Date()
        return d.formatted(.dateTime.hour())
    }
}
