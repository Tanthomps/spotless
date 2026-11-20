// Search tab: large title + pinned white field + browse tiles; tapping the field opens the focused
// search screen (recents → live results with category chips).
import SwiftUI

struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var moods: [MoodSection] = []
    @State private var art: [String: String] = [:]
    /// Start browsing's covers, filled as each page answers.
    @State private var startArt: [String: String] = [:]

    var body: some View {
        @Bindable var router = app.router
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    HStack(spacing: Space.m) {
                        Avatar()
                        Text("Search").font(Typo.largeTitle)
                        Spacer()
                        Icon(name: "camera", size: 26).accessibilityLabel("Scan")
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)
                    .padding(.bottom, Space.m)
                    .id("top")
                    Section {
                        tiles
                    } header: {
                        Button { router.searchFocused = true } label: { fakeField }
                            .buttonStyle(.plain)
                            .padding(.horizontal, Space.gutter)
                            .padding(.bottom, Space.s)
                            .background(Palette.base)
                    }
                }
            }
            .onChange(of: router.scrollToTopSerial[.search]) { _, _ in withAnimation { proxy.scrollTo("top") } }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if router.searchFocused {
                SearchFocusView().transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: router.searchFocused)
        .task {
            guard moods.isEmpty else { return }
            moods = (try? await app.core.getMoods()) ?? []
            art = (try? await app.core.getMoodArt(params: moods.flatMap { $0.items.map(\.params) })) ?? [:]
        }
        .task {
            guard startArt.isEmpty else { return }
            if let c = try? await app.core.getCharts(country: nil) { startArt["charts"] = c.featured.first?.thumbnail }
            if let n = try? await app.core.getNewReleases() { startArt["new"] = n.mix?.thumbnail ?? n.sections.first?.items.first?.thumbnail }
            startArt["mfy"] = app.settings.madeForYou.first { $0.thumbnail != nil }?.thumbnail
        }
    }

    private var fakeField: some View {
        HStack(spacing: Space.s) {
            Icon(name: "magnifying-glass", size: 22).foregroundStyle(Color(hex: "#121212"))
            Text(searchPrompt).font(Typo.font(16, .medium)).foregroundStyle(Color(hex: "#535353"))
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .frame(height: Metrics.searchField)
        .background(RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous).fill(.white))
        .accessibilityIdentifier("search-field")
    }

    /// Start browsing: the desktop's fixed tiles (Spotify iOS: Music · Podcasts · … ; Charts stands
    /// in for Music), then every genre and mood under Browse all.
    private var start: [(key: String, title: String, color: String, route: Route?)] {
        let f = BrowseTiles.fixed
        return [("charts", "Charts", f["charts"]!, .charts), ("podcasts", "Podcasts", f["podcasts"]!, nil),
                ("audiobooks", "Audiobooks", f["audiobooks"]!, nil), ("mfy", "Made for you", f["made_for_you"]!, .madeForYou),
                ("new", "New Releases", f["new_releases"]!, .newReleases)]
    }

    @ViewBuilder private var tiles: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Start browsing").font(Typo.font(16, .bold)).padding(.top, Space.m)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
                ForEach(start, id: \.key) { t in
                    Button {
                        if let r = t.route { app.router.push(r) } else { app.router.select(.home); app.router.homeChip = t.title }
                    } label: {
                        BrowseTile(title: t.title, color: Color(hex: t.color), art: startArt[t.key], tall: false)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("browse-\(t.key)")
                }
            }
            let all = moods.flatMap(\.items)
            if !all.isEmpty {
                Text("Browse all").font(Typo.font(16, .bold)).padding(.top, Space.m)
                grid(all, offset: 0, tall: true)
            }
        }
        .padding(.horizontal, Space.gutter)
    }

    private func grid(_ items: [Mood], offset: Int, tall: Bool) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
            ForEach(Array(items.enumerated()), id: \.element.params) { i, m in
                Button { app.router.push(.mood(m.params, m.title)) } label: {
                    // Our tile palette (`BrowseTiles`); YouTube's own mood colours are pastels.
                    BrowseTile(title: m.title, color: BrowseTile.color(offset + i), art: art[m.params], tall: tall)
                }
                .buttonStyle(PressScale())
            }
        }
    }

}

/// The Browse tile colours, the one list both apps use: exactly `crates/core/browse_tiles.json`
/// (the Mac imports that file; a test checks these against it). Swap colours there and here.
enum BrowseTiles {
    /// The five fixed "Start browsing" tiles.
    static let fixed: [String: String] = [
        "charts": "#6a2fd8", "podcasts": "#0b7a75", "audiobooks": "#c2410c", "made_for_you": "#1f4fa8", "new_releases": "#d6246e",
    ]
    /// Genre and mood tiles, in order, cycling.
    static let palette = ["#be123c", "#15803d", "#9d2bb0", "#0e6ba8", "#a16207", "#3f7d20",
                          "#b0279f", "#d6246e", "#0b7a75", "#6a2fd8", "#1f4fa8", "#c2410c"]
}

/// Coloured tile with the title top-left and a rotated cover peeking out bottom-right.
struct BrowseTile: View {
    let title: String
    let color: Color
    var art: String?
    var tall = false

    /// The n-th genre or mood tile's colour (`BrowseTiles.palette`, cycling).
    static func color(_ n: Int) -> Color { Color(hex: BrowseTiles.palette[n % BrowseTiles.palette.count]) }
    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous).fill(color)
            if let art {
                ArtImage(url: art, px: 200, radius: Radius.s)
                    .frame(width: tall ? 64 : 44, height: tall ? 64 : 44)
                    .rotationEffect(.degrees(25))
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: tall ? 14 : 8, y: tall ? 6 : 8)
            }
            Text(title).font(Typo.font(16, .bold)).foregroundStyle(.white).lineLimit(2)
                .padding(Space.m).frame(maxWidth: 130, alignment: .leading)
        }
        .frame(height: tall ? 96 : 58)
        .clipShape(RoundedRectangle(cornerRadius: Radius.s + 2, style: .continuous))
    }
}

// MARK: focused search

/// Our own placeholder (Spotify's wording is theirs).
let searchPrompt = "Songs, artists or podcasts"

struct SearchFocusView: View {
    @Environment(AppModel.self) private var app
    @FocusState private var focused: Bool
    @State private var query = ""
    @State private var results: SearchResults?
    // stream: search2 — the All view (`search_overview`) and the open chip's endless list.
    @State private var overview: SearchOverview?
    @State private var chipItems: [BrowseItem] = []
    @State private var chipEpisodes: [PodcastEpisode] = []
    @State private var chipQuery = ""
    @State private var chipNext: String?
    @State private var chipStarted = false
    @State private var chipLoading = false
    /// A tab's page failed: its list ends in "Couldn't load results · Try again" instead of placeholders.
    @State private var chipFailed = false
    @State private var chipCorrection: SearchCorrection?
    @State private var chipTryThese: SearchTryThese?
    /// stream: audiobooks — the best book matches, at the end of the Top list.
    @State private var topBooks: [BrowseItem] = []
    /// lyricsearch: a strong lyric match leads the Top list; the user touched the list → append only.
    @State private var lyricTop: SongItem?
    @State private var interacted = false
    @State private var failed = false
    @State private var retry = 0
    @State private var category: String?
    @State private var recents: [BrowseItem] = []
    /// Typeahead (`search_suggestions`): query rows over the results while typing (Spotify iOS).
    @State private var suggestions: [SearchSuggestions.Query] = []
    @State private var suggestFor = ""
    @State private var suggesting = false
    /// The suggestion just picked: putting it in the field is not typing.
    @State private var picked: String?
    /// The Videos chip's rows (`search_page` filter `videos`).
    @State private var chipVideos: [SongItem] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                HStack(spacing: Space.s) {
                    Icon(name: "magnifying-glass", size: 20).foregroundStyle(Palette.text)
                    TextField("", text: $query, prompt: Text(searchPrompt).foregroundStyle(Palette.subdued))
                        .font(Typo.font(16, .medium)).foregroundStyle(Palette.text)
                        .focused($focused).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("search-input")
                        // A pasted YouTube Music / YouTube / Spotify link opens what it points at.
                        // Only a paste (text arriving at once) or the Search key: typed character by
                        // character, a link parses early with a cut-off id ("youtu.be/4D7").
                        .onChange(of: query) { old, q in
                            guard q.count - old.count > 3 else { return }
                            openLink(q)
                        }
                        .onSubmit { suggesting = false; openLink(query) }
                        .onChange(of: query) { _, q in suggesting = (focused || suggesting) && !q.isEmpty && q != picked }
                    if !query.isEmpty {
                        Button { query = "" } label: { Icon(name: "x", size: 16).foregroundStyle(Palette.text).frame(width: 28, height: 36) }
                            .accessibilityLabel("Clear")
                    }
                }
                .padding(.horizontal, Space.m)
                .frame(height: 38)
                .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.elevatedHighlight))
                // "Cancel" 16/400 white (Spotify); returns to Browse and clears the query.
                Button("Cancel") {
                    focused = false
                    app.router.searchFocused = false
                    app.router.searchQuery = ""
                }
                .font(Typo.font(16)).foregroundStyle(Palette.text)
                .accessibilityIdentifier("search-cancel")
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.s)
            if query.isEmpty { recentsList } else { resultsList }
        }
        .foregroundStyle(Palette.text)
        .background(Color(hex: "#121212").ignoresSafeArea())
        .onAppear {
            query = app.router.searchQuery
            if let c = app.router.searchCategory { category = c; app.router.searchCategory = nil }
            if app.router.searchSuggest { suggesting = !query.isEmpty; app.router.searchSuggest = false }
            if query.isEmpty { focused = true }
            loadRecents()
        }
        .task(id: "\(query)#\(retry)") {
            guard !query.isEmpty else { results = nil; failed = false; return }
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            lyricTop = nil
            interacted = false
            // Songs by their words: alongside, never in front (empty at once unless it reads like lyrics).
            async let lyrics = app.core.searchLyrics(query: query)
            do {
                let o = try await app.core.searchOverview(query: query)
                guard !Task.isCancelled else { return }
                overview = o
                results = o.results
                failed = false
                let l = (try? await lyrics) ?? []
                guard !l.isEmpty, !Task.isCancelled,
                      let b = try? await app.core.searchBlendLyrics(query: query, songs: o.songs, lyric: l, interacted: interacted,
                                                             topTitle: o.topShow.map { o.shows[$0].title } ?? o.results.top.first.flatMap { $0.kind == .song ? nil : $0.title }),
                      !b.added.isEmpty, !Task.isCancelled else { return }
                overview?.songs = b.songs
                lyricTop = b.leadTop ? b.songs.first : nil
            } catch { if !Task.isCancelled { failed = true; results = nil; overview = nil } }
        }
        .task(id: "\(query)#\(category ?? "")#\(retry)") { await startChip() }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard suggesting, !q.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, let s = try? await app.core.searchSuggestions(query: q), !Task.isCancelled else { return }
            suggestions = s.queries
            suggestFor = query
        }
        .task(id: query) {
            topBooks = []
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 3 else { return }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let books = try? await app.core.audiobookSearch(query: q), q == query.trimmingCharacters(in: .whitespaces) else { return }
            topBooks = books.prefix(3).map(\.card)
        }
    }

    private func openLink(_ q: String) {
        guard q.contains("youtu") || q.contains("spotify."), let t = LinkTarget.parse(q) else { return }
        query = ""
        focused = false
        app.router.open(t, app: app)
    }

    private static let recentsKey = "searchRecents"
    /// UI tests start from the seeded recents every launch.
    private static let uitestReset: Void = {
        if ProcessInfo.processInfo.arguments.contains("-uitest") { UserDefaults.standard.removeObject(forKey: recentsKey) }
    }()

    /// Recent searches: what was opened from search results (kept across launches; ✕ and "Clear"
    /// stick). Before the first search they are seeded from recently played contexts.
    private func loadRecents() {
        _ = Self.uitestReset
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([BrowseItem].self, from: data) {
            recents = saved
        } else {
            recents = app.library.recents.compactMap(\.card).prefix(8).map { $0 }
        }
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(Array(recents.prefix(20))) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    private var recentsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !recents.isEmpty {
                    Text("Recent searches").font(Typo.font(16, .bold)).padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
                    ForEach(recents) { item in
                        ResultRow(item: item, trailingClear: true) { open(item) } onClear: {
                            recents.removeAll { $0.id == item.id }
                            saveRecents()
                        }
                    }
                    // Centred outline pill: 32 pt, 14/700, 1 px #7c7c7c border.
                    Button("Clear recent searches") { recents = []; saveRecents() }
                        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                        .padding(.horizontal, 16).frame(height: 32).overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                        .frame(maxWidth: .infinity).padding(.vertical, Space.l)
                        .accessibilityIdentifier("search-clear-recents")
                } else {
                    VStack(spacing: Space.s) {
                        Text("Find your next favourite").font(Typo.font(22, .bold))
                        Text("Look up songs, artists, albums and podcasts.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.horizontal, Space.xxl).padding(.top, 140)
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
        .chromeInset()
    }

    /// Spotify's chips; "Top" is the mixed list. Profiles are YouTube channels.
    private static let chips: [(String, String)] = [("Songs", "songs"), ("Artists", "artists"), ("Playlists", "playlists"),
        ("Albums", "albums"), ("Podcasts & Shows", "podcasts"), ("Audiobooks", "audiobooks"), ("Profiles", "profiles"), ("Episodes", "episodes"),
        ("Videos", "videos")]
    private var chipFilter: String? { Self.chips.first { $0.0 == category }?.1 }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        Chip(title: "Top", selected: category == nil) { category = nil }
                        ForEach(Self.chips, id: \.0) { c in
                            Chip(title: c.0, selected: category == c.0) { category = category == c.0 ? nil : c.0 }
                                .id(c.0)
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                }
                // A chip opened by a link (Videos is past the screen's edge) scrolls into view.
                .onAppear { if let c = category { proxy.scrollTo(c, anchor: .center) } }
            }
            .padding(.bottom, Space.s)
            if failed && category == nil {
                VStack(spacing: Space.m) {
                    Text("Couldn't load results").font(Typo.font(18, .bold))
                    Text("Check your connection and try again.").font(Typo.meta).foregroundStyle(Palette.subdued)
                    Button("Try again") { retry += 1 }
                        .font(Typo.font(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).frame(height: 36).background(Capsule().fill(.white))
                        .accessibilityIdentifier("search-retry")
                }
                .frame(maxWidth: .infinity).padding(.top, 100)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if showSuggestions {
                            ForEach(suggestions.prefix(4), id: \.self) { s in suggestionRow(s) }
                        }
                        if let line = correctionLine(category == nil ? overview?.correction : chipCorrection) {
                            Text(line).font(Typo.meta).foregroundStyle(Palette.subdued)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                                .accessibilityIdentifier("search-correction")
                        }
                        if category == nil {
                            if results == nil { ForEach(0..<8, id: \.self) { _ in skeletonRow } }
                            ForEach(Array(rows.enumerated()), id: \.element) { i, item in
                                ResultRow(item: item) { open(item) }.arriveRow(i)
                            }
                            if let t = overview?.tryThese { tryTheseRows(t) }
                            else if results != nil && rows.isEmpty { noResults }
                        } else if chipFilter == "videos" {
                            ForEach(Array(chipVideos.enumerated()), id: \.element.id) { i, v in
                                VideoResultRow(song: v) { openVideo(v) }
                                    .onAppear { if i >= chipVideos.count - 8 { Task { await loadMore() } } }
                            }
                        } else if chipFilter == "episodes" {
                            ForEach(Array(chipEpisodes.enumerated()), id: \.element.id) { i, e in
                                EpisodeRow(episode: e, showDescription: false) { playEpisodes(app, chipEpisodes, at: i) }
                                    .onAppear { if i >= chipEpisodes.count - 8 { Task { await loadMore() } } }
                            }
                        } else {
                            ForEach(Array(chipItems.enumerated()), id: \.element.id) { i, item in
                                ResultRow(item: item) { open(item) }
                                    .arriveRow(i)
                                    .onAppear { if i >= chipItems.count - 8 { Task { await loadMore() } } }
                            }
                        }
                        if category != nil && chipFailed && !chipLoading {
                            LoadMoreFailedRow(text: chipStarted ? "Couldn't load more" : "Couldn't load results") {
                                chipFailed = false; Task { await loadMore() }
                            }
                        } else if category != nil && (chipLoading || !chipStarted || chipNext != nil) {
                            ForEach(0..<(chipStarted ? 3 : 8), id: \.self) { _ in skeletonRow }
                                .onAppear { Task { await loadMore() } }
                        }
                        if category != nil, chipStarted, !chipFailed, chipNext == nil, chipItems.isEmpty, chipEpisodes.isEmpty, chipVideos.isEmpty {
                            noResults
                        }
                        if category != nil, chipStarted, chipNext == nil, let t = chipTryThese { tryTheseRows(t) }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in interacted = true; suggesting = false })
                .chromeInset()
            }
        }
    }

    private var showSuggestions: Bool {
        suggesting && suggestFor == query && !suggestions.isEmpty
    }

    /// A typeahead completion: tap searches it, the arrow puts it in the field to keep typing.
    private func suggestionRow(_ s: SearchSuggestions.Query) -> some View {
        HStack(spacing: Space.m) {
            Icon(name: s.history ? "clock-counter-clockwise" : "magnifying-glass", size: 20).foregroundStyle(Palette.subdued)
                .frame(width: Metrics.rowArt)
            Text(s.text).font(Typo.font(16)).lineLimit(1)
            Spacer(minLength: 0)
            Button { query = s.text + " " } label: {
                Icon(name: "arrow-left", size: 18).rotationEffect(.degrees(45)).foregroundStyle(Palette.subdued)
                    .frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fill in \(s.text)")
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: 52)
        .contentShape(Rectangle())
        .onTapGesture {
            suggesting = false
            picked = s.text
            focused = false
            query = s.text
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("search-suggestion")
    }

    private var noResults: some View {
        VStack(spacing: Space.s) {
            Text("No results for \"\(query)\"").font(Typo.font(16, .bold)).multilineTextAlignment(.center)
            Text("Check the spelling or try fewer words.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
        }
        .frame(maxWidth: .infinity).padding(.top, 60).padding(.horizontal, Space.xxl)
        .accessibilityIdentifier("search-no-results")
    }

    private var skeletonRow: some View {
        HStack(spacing: Space.m) {
            RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.elevatedHighlight).frame(width: Metrics.rowArt, height: Metrics.rowArt)
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(Palette.elevatedHighlight).frame(width: 160, height: 10)
                Capsule().fill(Palette.elevatedHighlight).frame(width: 100, height: 8)
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter).frame(height: Metrics.rowHeight)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func tryTheseRows(_ t: SearchTryThese) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Try these").font(Typo.font(18, .bold))
            Text("Nothing matched closely, so here's some of what you play most.").font(Typo.meta).foregroundStyle(Palette.subdued)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter).padding(.vertical, Space.m)
        .accessibilityIdentifier("search-try-these")
        ForEach(t.songs.map(\.card) + t.artists, id: \.self) { item in
            ResultRow(item: item) { open(item) }
        }
    }

    private func correctionLine(_ c: SearchCorrection?) -> String? {
        guard let c else { return nil }
        switch c.kind {
        case "offline": return "You're offline. Showing results from your library and downloads."
        case "library": return "Showing results from your library"
        default: return c.query.lowercased() == query.lowercased() ? nil : "Showing results for \(c.query)"
        }
    }

    /// A chip opened (or the query changed under it): its first page; Songs starts from the All
    /// view's page and token.
    private func startChip() async {
        chipItems = []; chipEpisodes = []; chipVideos = []; chipNext = nil; chipStarted = false; chipCorrection = nil; chipTryThese = nil; chipFailed = false
        guard let f = chipFilter, !query.isEmpty else { return }
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard !Task.isCancelled else { return }
        if f == "songs", let o = overview, !o.songs.isEmpty {
            chipQuery = o.query; chipItems = o.songs.map(\.card); chipNext = o.songsContinuation
            chipCorrection = o.correction; chipStarted = true
            return
        }
        chipQuery = query
        await loadMore()
    }

    /// The chip's next page (`search_page`), deduplicated.
    private func loadMore() async {
        guard let f = chipFilter, !chipLoading, !chipStarted || chipNext != nil else { return }
        chipLoading = true
        defer { chipLoading = false }
        let asked = query
        // stream: audiobooks — LibriVox books, one page (`audiobook_search`).
        if f == "audiobooks" {
            do {
                let books = try await app.core.audiobookSearch(query: query)
                guard asked == query, chipFilter == f else { return }
                chipItems = books.map(\.card); chipQuery = query; chipNext = nil; chipStarted = true; chipFailed = false
            } catch {
                if asked == query, chipFilter == f, !FriendlyError.isCancellation(error) { chipFailed = true }
            }
            return
        }
        let p: SearchPage
        do {
            p = try await app.core.searchPage(query: chipQuery.isEmpty ? query : chipQuery, filter: f, continuation: chipStarted ? chipNext : nil)
        } catch {
            if asked == query, chipFilter == f, !FriendlyError.isCancellation(error) { chipFailed = true }
            return
        }
        guard asked == query, chipFilter == f else { return }
        chipFailed = false
        if !chipStarted { chipQuery = p.query; chipCorrection = p.correction; chipTryThese = p.tryThese; chipStarted = true }
        let have = Set(chipItems.map(\.id) + chipEpisodes.map(\.id) + chipVideos.map(\.id))
        if f == "videos" { chipVideos += p.songs.filter { !have.contains($0.videoId) } }
        let cards = (f == "videos" ? [] : p.songs.map(\.card)) + p.items + p.shows.map(\.card)
        chipItems += cards.filter { !have.contains($0.id) }
        chipEpisodes += p.episodes.filter { !have.contains($0.id) }
        chipNext = p.continuation
    }

    private var rows: [BrowseItem] {
        guard let r = results else { return [] }
        var seen = Set<String>()
        let o = overview
        let songs = (o?.songs.isEmpty == false) ? o!.songs.map(\.card) : r.songs
        // A person's or a show's name: their show is the Top result (`top_show`), shows go first.
        var top = r.top
        if let i = o?.topShow, let shows = o?.shows, i < shows.count { top = [shows[i].card] }
        else if let l = lyricTop { top = [l.card] }
        let shows = Array((o?.shows ?? []).prefix(3).map(\.card))
        let lead = (o?.podcastsFirst ?? false) ? shows : []
        let tail = (o?.podcastsFirst ?? false) ? [] : shows
        // Built step by step: one long `+` chain is too much for the type checker on newer Xcode.
        var all: [BrowseItem] = top
        all += lead
        all += Array(songs.prefix(4))
        all += Array(r.artists.prefix(2))
        all += Array(r.albums.prefix(3))
        all += Array(r.playlists.prefix(3))
        all += tail
        all += topBooks
        all += Array(songs.dropFirst(4))
        return all.filter { seen.insert($0.id).inserted }
    }

    /// A video result: just this video, then Autoplay (kept whole: the row has no card round trip).
    private func openVideo(_ v: SongItem) {
        focused = false
        recents.removeAll { $0.id == v.videoId }
        recents.insert(v.card, at: 0)
        saveRecents()
        app.player.playSingle(v, from: query.isEmpty ? nil : query)
    }

    private func open(_ item: BrowseItem) {
        focused = false
        recents.removeAll { $0.id == item.id }
        recents.insert(item, at: 0)
        saveRecents()
        if item.kind == .song {
            // A single pick: only this song, then Autoplay. "Playing from search: <query>".
            let song = (overview?.songs ?? []).first { $0.videoId == item.id }
                ?? (results?.songs ?? []).first { $0.id == item.id }?.asSong ?? item.asSong
            app.player.playSingle(song, from: query.isEmpty ? nil : query)
        } else {
            app.router.open(item)
        }
    }
}

/// Search result / recent row: 48pt art (circle for artists), title, "Kind • subtitle".
/// Song results swipe like track rows (right: queue, left: Liked Songs); greyed ones say why.
struct ResultRow: View {
    @Environment(AppModel.self) private var app
    let item: BrowseItem
    var trailingClear = false
    var onTap: () -> Void
    var onClear: () -> Void = {}

    private var song: SongItem? { item.kind == .song ? item.asSong : nil }
    /// Why playback steps over this song (explicit filter, hidden, offline, unavailable): greyed.
    private var block: RowBlock? { song.flatMap { app.rowBlock($0) } }
    private var liked: Bool { app.library.isLiked(item.id) }

    var body: some View {
        HStack(spacing: Space.m) {
            if item.id == likedPlaylistId { LikedCover(size: Metrics.rowArt) } else {
                ArtImage(url: item.thumbnail, px: 144, radius: Radius.xs, circle: item.kind == .artist)
                    .frame(width: Metrics.rowArt, height: Metrics.rowArt)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(Typo.rowTitle)
                    .foregroundStyle(app.player.now?.videoId == item.id ? Palette.accentText : Palette.text).lineLimit(1)
                HStack(spacing: 5) {
                    if item.explicit == true { ExplicitBadge() }
                    Text(subtitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if trailingClear {
                Button(action: onClear) { Icon(name: "x", size: 16).foregroundStyle(Palette.subdued).frame(width: 40, height: 44) }
                    .accessibilityLabel("Remove")
            } else if let song {
                Button { app.sheet = .track(song, context: nil) } label: {
                    Icon(name: "dots-three", size: 20).foregroundStyle(Palette.subdued).frame(width: 40, height: 44)
                }
                .accessibilityLabel("More options")
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: Metrics.rowHeight)
        .opacity(block != nil ? 0.4 : 1)
        // Song rows swipe, results and recent searches alike: right adds to the queue, left saves.
        .rowSwipe(enabled: song != nil, liked: liked,
                  queue: { if let song { app.queue([song]) } }, like: { if let song { app.toggleLike(song) } })
        .contentShape(Rectangle())
        .onTapGesture {
            if let block, let song { app.explain(block, song) } else { onTap() }
        }
        .accessibilityAddTraits(.isButton)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.impact(.medium)
            app.sheet = song.map { .track($0, context: nil) } ?? .collection(item)
        } onPressingChanged: { down in
            // stream: firstaudio — the finger is down: start resolving before the tap lands.
            if down, block == nil, let song { app.core.hintPlay(song) }
        }
        .accessibilityIdentifier("result-row")
        .accessibilityValue(block == .explicit ? "explicit, unavailable" : block != nil ? "unavailable" : "")
        .accessibilityActions {
            if let song, !trailingClear {
                Button("Add to queue") { app.queue([song]) }
                Button(liked ? "Remove from Liked Songs" : "Add to Liked Songs") { app.toggleLike(song) }
            }
        }
    }

    /// Spotify: "Artist", "Song • X", "Album • X", "Playlist • X".
    private var subtitle: String {
        let kind = kindLabel(item.kind)
        if item.kind == .artist { return kind }
        var sub = item.subtitle ?? ""
        if item.kind == .song, sub.isEmpty || sub == kind, let runs = item.artistRuns, !runs.isEmpty {
            sub = runs.map(\.text).joined(separator: ", ")
        }
        if sub.isEmpty || sub == kind { return kind }
        return sub.hasPrefix(kind) ? sub : "\(kind) • \(sub)"
    }
}

/// A Videos chip row: the 16:9 frame with its length on it, the title, "Video • artist".
struct VideoResultRow: View {
    @Environment(AppModel.self) private var app
    let song: SongItem
    var onTap: () -> Void

    var body: some View {
        HStack(spacing: Space.m) {
            ArtImage(url: song.thumbnail, px: 240, radius: Radius.s)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let d = song.duration, !d.isEmpty {
                        Text(d).font(Typo.font(11, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.75)))
                            .padding(4)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(Typo.rowTitle)
                    .foregroundStyle(app.player.now?.videoId == song.videoId ? Palette.accentText : Palette.text).lineLimit(2)
                HStack(spacing: 5) {
                    if song.explicit == true { ExplicitBadge() }
                    Text("Video • \(song.artists)").font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button { app.sheet = .track(song, context: nil) } label: {
                Icon(name: "dots-three", size: 20).foregroundStyle(Palette.subdued).frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: 72)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.impact(.medium)
            app.sheet = .track(song, context: nil)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("video-row")
    }
}

/// Search results as a page (route `.searchResults`), for links that carry a query.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var app
    let query: String
    @State private var results: SearchResults?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        let items = (results?.top ?? []) + (results?.songs ?? []) + (results?.albums ?? [])
        ScrollView {
            LazyVStack(spacing: 0) {
                if results == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                else if items.isEmpty {
                    Text("No results for \"\(query)\"").font(Typo.font(16, .bold)).padding(.top, 60)
                }
                ForEach(Array(items.enumerated()), id: \.element) { i, item in
                    ResultRow(item: item) { app.router.open(item) }.arriveRow(i)
                }
            }
        }
        .navigationTitle(query)
        .background(Palette.base)
        .chromeInset()
        .task(id: attempt) {
            do { results = try await app.core.searchAll(query: query, recordHistory: true) } catch {
                if !FriendlyError.isCancellation(error) { failed = true }
            }
        }
    }
}

/// A mood/genre page: shelves of playlists (the desktop's genre page, `get_browse_sections`).
struct MoodView: View {
    @Environment(AppModel.self) private var app
    let params: String
    let title: String
    @State private var page: SectionsPage?
    @State private var failed = false
    @State private var attempt = 0
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                Text(title).font(Typo.font(28, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.s)
                if page == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                else if page?.sections.isEmpty == true {
                    Text("Nothing here right now").font(Typo.font(16, .bold)).frame(maxWidth: .infinity).padding(.top, 60)
                }
                ForEach(Array((page?.sections ?? []).enumerated()), id: \.element.title) { i, s in
                    VStack(alignment: .leading, spacing: Space.m) {
                        SectionTitle(title: s.title)
                        CardShelf(items: s.items)
                    }
                    .arriveBlock(i)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base)
        .chromeInset()
        .task(id: attempt) {
            do { page = try await app.core.getBrowseSections(browseId: moodsCategoryId, params: params) } catch {
                if !FriendlyError.isCancellation(error) { failed = true }
            }
        }
    }
}

