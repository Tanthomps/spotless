// Your Library (chips, sort, list/grid, pins) and Home (chips, 2-column shortcuts, shelves).
import SwiftUI

// MARK: shared shelf

struct CardShelf: View {
    @Environment(AppModel.self) private var app
    let items: [BrowseItem]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: Space.l) {
                ForEach(items, id: \.self) { item in
                    Button { tap(item) } label: {
                        MediaCard(title: item.title, subtitle: item.subtitle, thumbnail: item.thumbnail, circle: item.kind == .artist, liked: item.id == likedPlaylistId,
                                  fallback: ArtRef(id: item.id, title: item.title))
                    }
                    .buttonStyle(PressScale())
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                        Haptics.impact(.medium)
                        app.sheet = item.kind == .song ? .track(item.asSong, context: nil) : .collection(item)
                    })
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .scrollTargetBehavior(.viewAligned)
    }

    private func tap(_ item: BrowseItem) {
        if item.kind == .song {
            // A Home card is a single pick: the song, then Autoplay (not the rest of the shelf).
            app.player.playSingle(item.asSong)
        } else {
            app.router.open(item)
        }
    }
}

// MARK: library

/// One Your Library row: a saved/owned collection, a folder, a followed show, or the episodes tiles.
struct LibItem: Identifiable, Hashable {
    enum Row: Hashable { case collection, folder, yourEpisodes, newEpisodes }
    var id: String
    var kind: BrowseKind
    var title: String
    var subtitle: String
    var thumbnail: String?
    var pinned: Bool
    var added: Double
    var played: Double
    var creator: String
    var row: Row = .collection
    var order = 0
    var byYou = false
    var browse: BrowseItem { BrowseItem(kind: kind, id: id, title: title, subtitle: subtitle, thumbnail: thumbnail) }
    var pinnable: Bool { row == .collection || row == .folder }
}

/// Builds and filters Your Library's rows (shared by the library root and folder pages).
@MainActor enum LibraryRows {
    static func all(_ app: AppModel) -> [LibItem] {
        let lib = app.library
        let s = lib.snapshot
        let pins = s.pinnedIds
        let me = app.localUser
        // Recents: the core's play record, an own playlist's last edit (adding songs, renaming) and
        // local touches (a like moves Liked Songs; starting a context moves it before the core says so).
        var out: [LibItem] = [LibItem(id: likedPlaylistId, kind: .playlist, title: "Liked Songs", subtitle: "Playlist • \(counted(lib.likedIds.count, "song"))",
                                      thumbnail: nil, pinned: pins.contains(likedPlaylistId), added: .greatestFiniteMagnitude,
                                      played: lib.recentsKey(likedPlaylistId), creator: me, byYou: true)]
        for f in s.folders ?? [] {
            out.append(LibItem(id: f.id, kind: .playlist, title: f.name, subtitle: "Folder • \(counted(f.items.count, "playlist"))",
                               pinned: pins.contains(f.id), added: f.createdAt, played: lib.recentsKey(f.id, base: f.updatedAt), creator: me, row: .folder, byYou: true))
        }
        out += s.playlists.enumerated().map { i, p in
            LibItem(id: p.id, kind: .playlist, title: p.name, subtitle: "Playlist • \(me)", thumbnail: p.cover ?? p.thumbnail,
                    pinned: pins.contains(p.id), added: p.updatedAt, played: lib.recentsKey(p.id, base: max(p.lastPlayedAt ?? 0, p.updatedAt)),
                    creator: me, order: i, byYou: true)
        }
        out += s.saved.map { it in
            let creator = it.kind == .artist ? it.title : creatorOf(it.subtitle)
            let sub: String = switch it.kind {
            case .artist: "Artist"
            case .album: albumSubtitle(it.subtitle)
            case .playlist: creator.isEmpty ? "Playlist" : "Playlist • \(creator)"
            }
            return LibItem(id: it.id, kind: BrowseKind(rawValue: it.kind.rawValue) ?? .playlist, title: it.title, subtitle: sub,
                           thumbnail: it.thumbnail, pinned: pins.contains(it.id), added: it.addedAt, played: lib.recentsKey(it.id, base: it.addedAt),
                           creator: creator, order: 100)
        }
        // Signed in: the account's library playlists not already here (the desktop's sidebar rows).
        if app.account.signedIn {
            var seen = Set(out.map(\.id))
            for (i, p) in app.account.youtube.playlists.enumerated() where seen.insert(p.id).inserted {
                let own = app.account.youtube.owns(p.id)
                let creator = own ? me : creatorOf(p.subtitle)
                out.append(LibItem(id: p.id, kind: .playlist, title: p.title, subtitle: creator.isEmpty ? "Playlist" : "Playlist • \(creator)",
                                   thumbnail: p.thumbnail, pinned: pins.contains(p.id), added: 0, played: lib.recentsKey(p.id),
                                   creator: creator, order: 150 + i, byYou: own))
            }
        }
        out.append(LibItem(id: "your-episodes", kind: .podcast, title: "Your Episodes", subtitle: "Saved & downloaded episodes",
                           pinned: false, added: 0, played: app.podcasts.saved.first?.progress.updatedAt ?? 1, creator: "", row: .yourEpisodes))
        out += app.podcasts.follows.map { sh in
            LibItem(id: sh.id, kind: .podcast, title: sh.title, subtitle: "Podcast • \(sh.author)", thumbnail: sh.thumbnail,
                    pinned: pins.contains(sh.id), added: 0, played: lib.recentsKey(sh.id), creator: sh.author, order: 200)
        }
        // stream: audiobooks — saved books.
        out += app.books.saved.map { b in
            LibItem(id: b.id, kind: .audiobook, title: b.title, subtitle: "Audiobook • \(b.author)", thumbnail: b.thumbnail,
                    pinned: pins.contains(b.id), added: 0, played: lib.recentsKey(b.id), creator: b.author, order: 300)
        }
        return out
    }

    static func sort(_ items: [LibItem], _ by: LibrarySort) -> [LibItem] {
        let sorted: [LibItem] = switch by {
        case .recents: items.sorted { $0.played > $1.played }
        case .added: items.sorted { $0.added > $1.added }
        case .alphabetical: items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .creator: items.sorted {
            let c = $0.creator.localizedCaseInsensitiveCompare($1.creator)
            return c == .orderedSame ? $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending : c == .orderedAscending
        }
        case .custom: items.sorted { $0.order < $1.order }
        }
        // Pinned first (in pin order), whatever the sort.
        let pins = sorted.filter(\.pinned)
        return pins + sorted.filter { !$0.pinned }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var scrolled = false
    @FocusState private var searchFocused: Bool

    private static let chips = ["Playlists", "Podcasts", "Audiobooks", "Albums", "Artists", "Downloaded"] // Audiobooks: stream audiobooks

    private func subChips(_ f: String) -> [String] {
        switch f {
        case "Playlists": ["By you"]
        case "Downloaded": ["Playlists", "Albums", "Podcasts"]
        default: []
        }
    }

    private var items: [LibItem] {
        var out = LibraryRows.all(app)
        let inFolder = Set((app.library.snapshot.folders ?? []).flatMap(\.items))
        let downloaded = Set(app.downloads.snapshot.collections.map(\.id))
        switch app.libraryFilter {
        case "Playlists":
            out = out.filter { $0.kind == .playlist }
            if app.librarySubFilter == "By you" { out = out.filter(\.byYou) }
        case "Podcasts":
            out = out.filter { $0.kind == .podcast }
            if !app.podcasts.newEpisodes.isEmpty {
                out.insert(LibItem(id: "new-episodes", kind: .podcast, title: "New Episodes", subtitle: "Updated \(episodeDate(app.podcasts.newEpisodes.first?.publishedAt))",
                                   pinned: false, added: 0, played: 2, creator: "", row: .newEpisodes), at: 0)
            }
        case "Albums": out = out.filter { $0.kind == .album }
        case "Artists": out = out.filter { $0.kind == .artist }
        case "Audiobooks": out = out.filter { $0.kind == .audiobook }
        case "Downloaded":
            // A book's download is the collection `abook:<id>`.
            // Downloaded episodes are saved to Your Episodes, so that row is listed too.
            let episodes = app.downloads.snapshot.collections.contains { $0.kind == "episode" }
            out = out.filter { downloaded.contains($0.kind == .audiobook ? "abook:\($0.id)" : $0.id) || ($0.row == .yourEpisodes && episodes) }
            switch app.librarySubFilter {
            case "Playlists": out = out.filter { $0.kind == .playlist }
            case "Albums": out = out.filter { $0.kind == .album }
            case "Podcasts": out = out.filter { $0.kind == .podcast }
            default: break
            }
        default:
            break
        }
        // Folder contents live on the folder page (except when a type filter flattens the tree).
        if app.libraryFilter == nil || app.libraryFilter == "Playlists" { out = out.filter { !inFolder.contains($0.id) } }
        if let q = app.librarySearch?.trimmingCharacters(in: .whitespaces), !q.isEmpty {
            out = out.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q) }
        }
        return LibraryRows.sort(out, app.librarySort)
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                if app.librarySearch != nil { searchField }
                chips
            }
            .background(scrolled ? Color(hex: "#1a1a1a") : Palette.base)
            .overlay(alignment: .bottom) { if scrolled { Rectangle().fill(Color.black.opacity(0.6)).frame(height: 0.5).shadow(color: .black.opacity(0.5), radius: 4, y: 2) } }
            .zIndex(1)
            .animation(.easeOut(duration: 0.15), value: scrolled)
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { g in Color.clear.preference(key: LibScrollKey.self, value: g.frame(in: .named("lib")).minY) }.frame(height: 0)
                    sortRow.id("top")
                    if !app.library.loaded {
                        if app.library.failed {
                            EntityLoadState(failed: true) { app.library.failed = false; Task { await app.library.refresh() } }
                        } else {
                            SkeletonRows(count: 8)
                        }
                    } else {
                        if libraryEmpty { emptyState }
                        if app.libraryFilter == "Downloaded" { DownloadsRetryRow() }
                        if app.libraryGrid { gridView(list) } else { listView(list) }
                        if list.isEmpty && !libraryEmpty { emptyState }
                    }
                }
                .coordinateSpace(name: "lib")
                .onPreferenceChange(LibScrollKey.self) { y in scrolled = y < -2 }
                .scrollDismissesKeyboard(.immediately)
                .onChange(of: app.router.scrollToTopSerial[.library]) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .task { await app.library.refresh(); await app.downloads.refresh() }
    }

    private var header: some View {
        HStack(spacing: Space.m) {
            Avatar()
            Text("Your Library").font(Typo.largeTitle)
            Spacer()
            Button {
                Haptics.selection()
                withAnimation(Motion.quick) { app.librarySearch = app.librarySearch == nil ? "" : nil }
                searchFocused = app.librarySearch != nil
            } label: { Icon(name: "magnifying-glass", size: 24) }
            .accessibilityLabel("Search Your Library")
            .accessibilityIdentifier("library-search")
            Button { app.sheet = .create } label: { Icon(name: "plus", size: 24) }
                .accessibilityLabel("Create").padding(.leading, Space.m)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.top, Space.s)
        .padding(.bottom, Space.m)
    }

    private var searchField: some View {
        @Bindable var app = app
        return HStack(spacing: Space.m) {
            HStack(spacing: Space.s) {
                Icon(name: "magnifying-glass", size: 16).foregroundStyle(Palette.text)
                TextField("", text: Binding(get: { app.librarySearch ?? "" }, set: { app.librarySearch = $0 }),
                          prompt: Text("Search Your Library").foregroundStyle(Palette.subdued))
                    .font(Typo.font(14)).focused($searchFocused).submitLabel(.search)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("library-search-field")
                if !(app.librarySearch ?? "").isEmpty {
                    Button { app.librarySearch = "" } label: { Icon(name: "x", size: 14).foregroundStyle(Palette.subdued) }
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.s).fill(Color(hex: "#2a2a2a")))
            Button("Cancel") {
                searchFocused = false
                withAnimation(Motion.quick) { app.librarySearch = nil }
            }
            .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.bottom, Space.m)
        .transition(Motion.slide(.top, fade: true))
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                if let f = app.libraryFilter {
                    Button {
                        Haptics.selection()
                        withAnimation(Motion.quick) { app.libraryFilter = nil; app.librarySubFilter = nil }
                    } label: {
                        Icon(name: "x", size: 16).frame(width: Metrics.chipHeight, height: Metrics.chipHeight).background(Circle().fill(Color(hex: "#2a2a2a")))
                    }
                    .accessibilityLabel("Clear filter")
                    .accessibilityIdentifier("library-clear-filter")
                    Chip(title: f, selected: true) {
                        withAnimation(Motion.quick) { app.libraryFilter = nil; app.librarySubFilter = nil }
                    }
                    ForEach(subChips(f), id: \.self) { c in
                        Chip(title: c, selected: app.librarySubFilter == c) {
                            withAnimation(Motion.quick) { app.librarySubFilter = app.librarySubFilter == c ? nil : c }
                        }
                    }
                } else {
                    ForEach(Self.chips.filter { $0 != "Downloaded" || !app.downloads.snapshot.collections.isEmpty }, id: \.self) { c in
                        Chip(title: c) { withAnimation(Motion.quick) { app.libraryFilter = c; app.librarySubFilter = nil } }
                            .accessibilityIdentifier("library-chip-\(c)")
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .padding(.bottom, Space.s)
    }

    private var sortRow: some View {
        HStack {
            Button { app.sheet = .sort } label: {
                // ↓↑ glyph 16 pt + the sort name 14/400 white.
                HStack(spacing: 6) {
                    Icon(name: "arrows-down-up", size: 16)
                    Text(app.librarySort.rawValue).font(Typo.font(14))
                }
                .frame(height: 28)
            }
            .accessibilityIdentifier("library-sort")
            Spacer()
            Button { Haptics.selection(); withAnimation(Motion.quick) { app.libraryGrid.toggle() } } label: {
                IconSwap(name: app.libraryGrid ? "list-bullets" : "squares-four", size: 20)
            }
            .accessibilityLabel(app.libraryGrid ? "Show as list" : "Show as grid")
        }
        .foregroundStyle(Palette.text)
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.s)
    }

    /// Nothing saved at all (Liked Songs and Your Episodes are always listed, so `items` is never empty).
    private var libraryEmpty: Bool {
        let s = app.library.snapshot
        return app.libraryFilter == nil && (app.librarySearch ?? "").isEmpty && s.playlists.isEmpty && s.saved.isEmpty
            && app.library.likedIds.isEmpty && app.podcasts.follows.isEmpty
    }

    /// A centred 16/700 line and a 14 subdued line; with nothing in the library at all, the white
    /// "Create a playlist" pill (Spotify's empty-library call to action).
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: Space.s) {
            if app.librarySearch.map({ !$0.isEmpty }) == true {
                Text("No matches for \"\(app.librarySearch ?? "")\"").font(Typo.font(16, .bold))
                Text("Check the spelling, or try a shorter word.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
            } else if app.libraryFilter == "Downloaded" {
                Text("Nothing downloaded yet").font(Typo.font(16, .bold))
                Text("Download music and podcasts to listen offline.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
            } else if let f = app.libraryFilter {
                Text("No \(f.lowercased()) yet").font(Typo.font(16, .bold))
                Text(f == "Artists" ? "Follow artists and they show up here." : f == "Podcasts" ? "Follow shows and they show up here."
                     : "Save \(f.lowercased()) and they show up here.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
            } else {
                Text("Start your library").font(Typo.font(16, .bold))
                Text("Make playlists and save music you love.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                Button { app.sheet = .newPlaylist } label: {
                    Text("Create a playlist").font(Typo.font(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 24).frame(height: 40).background(Capsule().fill(.white))
                }
                .buttonStyle(PressScale())
                .padding(.top, Space.m)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, Space.xxl)
        .padding(.top, 60)
    }

    private func listView(_ list: [LibItem]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { i, it in LibraryRow(item: it).arriveRow(i) }
        }
    }

    private func gridView(_ list: [LibItem]) -> some View {
        // 3 columns, 16 pt gaps; title 14/700 and subtitle 13 subdued under each tile.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.l, alignment: .top), count: 3), spacing: Space.l) {
            ForEach(list) { it in
                VStack(alignment: it.kind == .artist ? .center : .leading, spacing: 4) {
                    LibraryArt(item: it, size: nil).aspectRatio(1, contentMode: .fit).padding(.bottom, 4)
                    Text(it.title).font(Typo.font(14, .bold)).lineLimit(1)
                    HStack(spacing: 4) {
                        if it.pinned { Icon(name: "push-pin", fill: true, size: 12).foregroundStyle(Palette.accent) }
                        CollectionDownloadGlyph(id: it.id)
                        Text(it.subtitle).font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { openLibItem(app, it) }
                .accessibilityAddTraits(.isButton)
                .onLongPressGesture(minimumDuration: 0.4) { if it.pinnable { Haptics.impact(.medium); app.sheet = .collection(it.browse) } }
            }
        }
        .padding(.horizontal, Space.gutter)
    }
}

private struct LibScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Whether the queue plays this library item (Liked Songs has two ids: `VLLM` and the core's "liked").
@MainActor func isPlayingContext(_ app: AppModel, _ id: String) -> Bool {
    guard let src = app.player.queue.sourceId, !app.player.queue.items.isEmpty else { return false }
    return HomeStore.key(src) == HomeStore.key(id)
}

/// The creator in a YouTube card subtitle ("Album • Daft Punk • 2001", "Playlist • Owner • 12 songs",
/// "Single • Artist", "Daft Punk"): drop type words and trailing year, count and duration parts.
/// The desktop's `creatorOf` (`libraryItems.svelte.ts`).
func creatorOf(_ subtitle: String?) -> String {
    let types: Set<String> = ["album", "single", "ep", "playlist", "artist", "podcast", "song", "video", "episode", "mix", "radio", "compilation", "live"]
    let parts = (subtitle ?? "").components(separatedBy: CharacterSet(charactersIn: "•·"))
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return parts.first { p in
        let l = p.lowercased()
        if types.contains(l) { return false }
        if p.count == 4, Int(p) != nil { return false }
        if l.range(of: #"^[\d.,]+[kmb]?\s+(songs?|tracks?|views?|episodes?|subscribers?|monthly|plays?)"#, options: .regularExpression) != nil { return false }
        if l.range(of: #"^\d+\s*(hours?|hr|minutes?|min|seconds?|sec)\b"#, options: .regularExpression) != nil { return false }
        return true
    } ?? ""
}

@MainActor func openLibItem(_ app: AppModel, _ it: LibItem) {
    switch it.row {
    case .folder: app.router.push(.folder(it.id))
    case .yourEpisodes: app.router.push(.yourEpisodes)
    case .newEpisodes: app.router.push(.newEpisodes)
    case .collection: app.router.open(it.browse)
    }
}

/// Square art (circle for artists), Liked Songs / folder / episodes tiles.
struct LibraryArt: View {
    let item: LibItem
    var size: CGFloat?
    var body: some View {
        Group {
            switch item.row {
            case .folder:
                tile(Color(hex: "#333333")) { g in Icon(name: "folder", size: g * 0.42).foregroundStyle(Palette.subdued) }
            case .yourEpisodes:
                tile(Palette.accentTile) { g in Image(systemName: "bookmark.fill").font(.system(size: g * 0.36)).foregroundStyle(Palette.accent) }
            case .newEpisodes:
                tile(Color(hex: "#5038a0")) { g in Icon(name: "bell", fill: true, size: g * 0.42).foregroundStyle(.white) }
            case .collection:
                if item.id == likedPlaylistId {
                    GeometryReader { g in LikedCover(size: g.size.width) }
                } else {
                    ArtImage(url: item.thumbnail, px: 200, radius: item.kind == .podcast ? Radius.m : Radius.xs, circle: item.kind == .artist,
                             fallback: ArtRef(id: item.id, title: item.title))
                }
            }
        }
        .frame(width: size, height: size)
    }

    private func tile(_ bg: Color, @ViewBuilder _ glyph: @escaping (CGFloat) -> some View) -> some View {
        GeometryReader { g in
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(bg)
                .overlay(glyph(g.size.width))
        }
    }
}

/// A Your Library list row: 64 pt art, title (accent while its context plays), pin / download
/// glyphs before the subtitle. Swipe right pins/unpins (Spotify), long-press opens the sheet.
struct LibraryRow: View {
    @Environment(AppModel.self) private var app
    let item: LibItem
    @State private var dx: CGFloat = 0
    @State private var armed = false
    @State private var axis: Axis?
    private let threshold: CGFloat = 80

    var body: some View {
        ZStack(alignment: .leading) {
            HStack {
                Icon(name: "push-pin", fill: !item.pinned, size: 22).foregroundStyle(armed ? Color.black : Palette.text).padding(.leading, 24)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(armed ? Palette.accent : Palette.highlight)
            .opacity(dx > 4 ? 1 : 0)

            content
                .background(Palette.base.opacity(dx > 0 ? 1 : 0.001))
                .offset(x: dx)
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { openLibItem(app, item) }
        .accessibilityAddTraits(.isButton)
        .onLongPressGesture(minimumDuration: 0.4) {
            guard item.pinnable else { return }
            Haptics.impact(.medium); app.sheet = .collection(item.browse)
        }
        .simultaneousGesture(swipe, including: item.pinnable ? .all : .none)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-row")
        .accessibilityAction(named: item.pinned ? "Unpin" : "Pin") { pin() }
    }

    private var content: some View {
        let playing = isPlayingContext(app, item.id)
        return HStack(spacing: Space.m) {
            LibraryArt(item: item, size: Metrics.libraryRowArt)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Typo.rowTitle)
                    .foregroundStyle(playing ? Palette.accentText : Palette.text).lineLimit(1)
                HStack(spacing: 5) {
                    if item.pinned { Icon(name: "push-pin", fill: true, size: 12).foregroundStyle(Palette.accent) }
                    CollectionDownloadGlyph(id: item.id)
                    Text(item.subtitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            // Spotify: the playing context's row gets the accent equaliser at its right edge.
            if playing {
                EqualizerGlyph(animating: !app.player.paused)
                    .accessibilityLabel(app.player.paused ? "Paused" : "Playing")
                    .accessibilityIdentifier("library-row-playing")
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, 6)
    }

    private func pin() {
        app.library.setPinned(item.browse, !item.pinned)
        app.showToast(item.pinned ? "Unpinned" : "Pinned")
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { v in
                if axis == nil { axis = abs(v.translation.width) > abs(v.translation.height) && v.translation.width > 0 ? .horizontal : .vertical }
                guard axis == .horizontal else { return }
                let x = max(0, v.translation.width)
                dx = x < threshold ? x : threshold + (x - threshold) * 0.3
                let now = x >= threshold
                if now != armed { armed = now; Haptics.impact(.light) }
            }
            .onEnded { _ in
                if axis == .horizontal && armed { pin() }
                axis = nil
                armed = false
                withAnimation(Motion.spring) { dx = 0 }
            }
    }
}

// MARK: home

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var chip = "All"
    @State private var tint: UIColor?

    static let chips = ["All", "Music", "Podcasts", "Audiobooks"] // Audiobooks: stream audiobooks

    /// What Home shows (offline the core sends only what's on the phone); under "Music", no podcasts.
    private var shelves: [Shelf] {
        if chip == "Podcasts" { return app.home.podcastShelves }
        if chip == "Audiobooks" { return app.home.audiobookShelves }
        return chip == "Music" ? HomeStore.musicOnly(app.home.shelves) : app.home.shelves
    }

    /// The desktop's Home states (`+page.svelte`): skeletons until the first answer, the error
    /// with Reload when it failed with nothing to show, "Nothing here yet" when it's empty.
    private enum Phase { case loading, failed, empty, shelves }
    /// `mixes`: the stored Made for you shelf counts as something to show.
    private func phase(_ shelves: [Shelf], mixes: Bool) -> Phase {
        if chip == "Podcasts" || chip == "Audiobooks" {
            let pods = chip == "Podcasts"
            if shelves.isEmpty && (pods ? app.home.podcastsFailed : app.home.audiobooksFailed) { return .failed }
            if shelves.isEmpty && !(pods ? app.home.podcastsLoaded : app.home.audiobooksLoaded) { return .loading }
            return shelves.isEmpty ? .empty : .shelves
        }
        guard chip == "All" || chip == "Music" else { return .shelves }
        if shelves.isEmpty && app.home.failed { return .failed }
        if shelves.isEmpty && !app.home.loaded { return .loading }
        return mixes || shelves.contains { $0.layout == .notice || !$0.items.isEmpty } ? .shelves : .empty
    }

    var body: some View {
        let shelves = shelves
        let offline = app.downloads.offline
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.m) {
                        chipRow
                            .id("top")
                        if app.devices.showsHint && !offline { DeviceLinkHint().padding(.horizontal, Space.gutter) }
                        if let n = shelves.first(where: { $0.layout == .notice }) { notice(n) }
                        if let s = shelves.first(where: { $0.layout == .shortcuts }) { shortcuts(s.items) }
                    }
                    // smart2: Made for you right after Recently played (first when there is none yet).
                    // The stored mixes replace the core's own "made_for_you" shelf, never both.
                    let mixes = !app.settings.madeForYou.isEmpty && !offline
                    let ph = phase(shelves, mixes: mixes)
                    switch ph {
                    case .loading: skeletons
                    case .failed: failedState
                    case .empty: emptyState
                    case .shelves: EmptyView()
                    }
                    let hasMfy = mixes && ph == .shelves
                    let feed = shelves.filter { $0.layout != .shortcuts && $0.layout != .notice && !(hasMfy && $0.id == "made_for_you") }
                    if hasMfy && chip != "Podcasts" && chip != "Audiobooks" && !feed.contains(where: { $0.id == "recently_played" }) { MadeForYouShelf() }
                    ForEach(Array(feed.enumerated()), id: \.element.id) { idx, shelf in
                        VStack(alignment: .leading, spacing: Space.m) {
                            // Every shelf opens as a grid (Spotify's "Show all"); moods are tiles already.
                            if shelf.layout == .moods || shelf.items.count < 3 {
                                SectionTitle(title: shelf.title)
                            } else {
                                Button { app.router.push(.shelf(shelf.id, shelf.title)) } label: { SectionTitle(title: shelf.title, showAll: true) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(shelf.title), Show all")
                                    .accessibilityIdentifier("home-show-all")
                            }
                            // Moods & genres and podcast categories: Search's Browse tiles.
                            if shelf.layout == .moods { moodTiles(shelf.items) } else { CardShelf(items: shelf.items.map(homeBrowseItem)) }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("home-shelf")
                        .arriveBlock(idx + 1)
                        if hasMfy && shelf.id == "recently_played" { MadeForYouShelf() }
                        // The desktop's "Your shows": on All, after the second shelf (Made for you counts).
                        if idx == (hasMfy ? 0 : 1) && chip == "All" && !app.podcasts.follows.isEmpty { yourShows }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.top, Space.s)
            }
            .onChange(of: shelves.count) { _, _ in
                if app.router.homeScrollEnd { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onChange(of: app.router.scrollToTopSerial[.home]) { _, _ in
                // Re-tapping Home pops a "Show all" page first (Router.select), then scrolls to top.
                withAnimation { proxy.scrollTo("top", anchor: .top) }
            }
        }
        .foregroundStyle(Palette.text)
        .background(alignment: .top) {
            LinearGradient(colors: [tint?.surface(value: 0.35, maxSaturation: 0.6) ?? Palette.base, Palette.base], startPoint: .top, endPoint: .bottom)
                .frame(height: 320).ignoresSafeArea()
                .animation(.easeInOut(duration: 1), value: tint)
        }
        .background(Palette.base)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .artAccent(shelves.first?.items.first(where: { $0.thumbnail != nil })?.thumbnail, into: $tint)
        // The desktop's Home: load, reload on `home-changed` (a context switch, YouTube's shelves
        // arriving late, Made for you rebuilt, the network flipping), on coming back to the app,
        // and on pull-to-refresh. Starting a context moves its tile at once (`HomeStore.touch`).
        .task(id: app.homeSerial) { await load() }
        .refreshable {
            await load()
            // A pull that failed with shelves still showing: say so instead of nothing.
            if !app.home.shelves.isEmpty && app.home.lastFetchFailed { app.fail("Couldn't refresh Home. Check your connection.") }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await load() }
        }
        // Back on Home after a while (you listened, liked, followed): Recents and Made for you move.
        .onChange(of: app.router.tab) { _, t in
            if t == .home, Date().timeIntervalSince(app.home.loadedAt) > 60 { Task { await load() } }
        }
        .onChange(of: app.router.homeChip, initial: true) { _, c in if let c { chip = c; app.router.homeChip = nil } }
        .task(id: chip) {
            if chip == "Podcasts" { await app.home.loadPodcasts() }
            if chip == "Audiobooks" { await app.home.loadAudiobooks() }
        }
    }

    /// Spotify's chip row: avatar and every chip always there, scrolling sideways when they don't
    /// fit. The picked chip is filled; tapping it again (or All) goes back to All.
    private var chipRow: some View {
        HStack(spacing: Space.s) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        // Spotify has no bell: What's New lives in the side menu, flagged by a blue dot on the avatar.
                        Avatar()
                            .overlay(alignment: .topTrailing) {
                                if app.settings.whatsNewCount > 0 {
                                    Circle().fill(Palette.announcement).frame(width: 9, height: 9)
                                        .overlay(Circle().stroke(Palette.base, lineWidth: 1.5))
                                        .accessibilityLabel("New in What's New")
                                }
                            }
                        ForEach(Self.chips, id: \.self) { c in
                            Chip(title: c, selected: c == chip, compact: true) { select(c) }
                                .fixedSize()
                                .id(c)
                                .accessibilityIdentifier("home-chip-\(c)")
                                .accessibilityAddTraits(c == chip ? .isSelected : [])
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                }
                // The picked chip is always fully in view (a deep link can pick one off-screen).
                .onChange(of: chip, initial: true) { _, c in withAnimation(Motion.quick) { proxy.scrollTo(c) } }
            }
        }
    }

    /// The picked chip again means "All".
    private func select(_ c: String) {
        let next = c == chip ? "All" : c
        guard next != chip else { return }
        Haptics.selection()
        withAnimation(Motion.quick) { chip = next }
    }

    /// Offline Home's header: the core's "You're offline" notice (`offline_home`).
    private func notice(_ s: Shelf) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(s.title).font(Typo.font(16, .bold))
            if let sub = s.subtitle { Text(sub).font(Typo.meta).foregroundStyle(Palette.subdued) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.gutter)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("home-offline")
    }

    /// While the first `smart_home` answer is on its way: grey shortcut tiles and card shelves.
    private var skeletons: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
                ForEach(0..<8, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: Radius.s).fill(Palette.tinted).frame(height: Metrics.shortcutHeight)
                }
            }
            .padding(.horizontal, Space.gutter)
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Space.m) {
                    RoundedRectangle(cornerRadius: Radius.s).fill(Palette.tinted).frame(width: 200, height: 20)
                    HStack(spacing: Space.l) {
                        ForEach(0..<2, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: Radius.s).fill(Palette.tinted).frame(width: Metrics.card, height: Metrics.card)
                        }
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
        .accessibilityIdentifier("home-loading")
    }

    /// The desktop's ErrorState: "Something went wrong", "Try reloading the page.", Reload.
    private var failedState: some View {
        VStack(spacing: Space.m) {
            Icon(name: "warning-circle", size: 56).foregroundStyle(Palette.subdued)
            Text("Something went wrong").font(Typo.font(24, .bold))
            Text("Try reloading the page.").font(Typo.font(16)).foregroundStyle(Palette.subdued)
            Button {
                app.home.failed = false; app.home.podcastsFailed = false; app.home.audiobooksFailed = false
                Task { await load() }
            } label: {
                Text("Reload").font(Typo.button).foregroundStyle(.black)
                    .padding(.horizontal, 32).frame(height: 48).background(Capsule().fill(.white))
            }
            .buttonStyle(PressScale())
            .accessibilityIdentifier("home-retry")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, Space.gutter)
        .accessibilityIdentifier("home-error")
    }

    /// Nothing played yet and nothing from YouTube: the desktop's "Nothing here yet".
    private var emptyState: some View {
        VStack(spacing: Space.l) {
            Text("Nothing here yet").font(Typo.font(20, .bold))
            Text("Play something and Home fills up with your mixes, recents and new releases.")
                .font(Typo.font(16)).foregroundStyle(Palette.subdued)
            Button { app.router.select(.search) } label: {
                Text("Browse all").font(Typo.button).foregroundStyle(.black)
                    .padding(.horizontal, 32).frame(height: 48).background(Capsule().fill(.white))
            }
            .buttonStyle(PressScale())
            .accessibilityIdentifier("home-browse-all")
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64)
        .padding(.horizontal, Space.gutter)
        .accessibilityIdentifier("home-empty")
    }

    /// The shows you follow (the desktop's "Your shows" shelf on All).
    private var yourShows: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionTitle(title: "Your shows")
            CardShelf(items: app.podcasts.follows.map {
                BrowseItem(kind: .podcast, id: $0.id, title: $0.title, subtitle: $0.author, thumbnail: $0.thumbnail)
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-your-shows")
    }

    private func load() async {
        // Made for you builds from your listening (the first build happens once there is some).
        if !app.downloads.offline {
            Task { if let c = try? await app.core.madeForYou(), !c.isEmpty { app.settings.madeForYou = c } }
        }
        if chip == "Podcasts" { await app.home.loadPodcasts() }
        if chip == "Audiobooks" { await app.home.loadAudiobooks() }
        await app.home.load { [app] in app.downloads.offline }
    }

    private func moodTiles(_ items: [ShelfItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: [GridItem(.fixed(96), spacing: Space.s), GridItem(.fixed(96), spacing: Space.s)], spacing: Space.s) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, m in
                    let book = m.kind == "audiobook_genre" // stream: audiobooks
                    let category = m.kind == "podcast_category" || book
                    Button {
                        if book { app.router.push(.shelf("abgenre:\(m.params ?? m.id)", m.title)) }
                        else if category { app.router.push(.shelf(m.id, m.title)) } else { app.router.push(.mood(m.params ?? m.id, m.title)) }
                    } label: {
                        // Search's Browse-all tile: its palette for moods, the category's own colour.
                        BrowseTile(title: m.title, color: category ? Color(hex: m.color ?? "#2a2a2a") : BrowseTile.color(i),
                                   art: m.thumbnail, tall: true)
                            .frame(width: 172)
                    }
                    .buttonStyle(PressScale())
                    .accessibilityIdentifier("home-tile")
                }
            }
            .padding(.horizontal, Space.gutter)
        }
    }

    private func shortcuts(_ items: [ShelfItem]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.s), GridItem(.flexible(), spacing: Space.s)], spacing: Space.s) {
            ForEach(items.prefix(8)) { it in
                Button { app.router.open(homeBrowseItem(it)) } label: {
                    HStack(spacing: Space.s) {
                        if it.kind == "liked" { LikedCover(size: Metrics.shortcutHeight).clipShape(Rectangle()) } else {
                            ArtImage(url: it.thumbnail, px: 160, radius: 0, circle: false, fallback: ArtRef(id: it.id, title: it.title))
                                .frame(width: Metrics.shortcutHeight, height: Metrics.shortcutHeight)
                        }
                        let ep = episodeTile(it)
                        if ep.isNew {
                            Circle().fill(Palette.announcement).frame(width: 8, height: 8)
                                .accessibilityLabel("New episode")
                                .accessibilityIdentifier("shortcut-new")
                        }
                        Text(it.title).font(Typo.shortcut).foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if isPlayingContext(app, it.id) {
                            EqualizerGlyph(animating: !app.player.paused).padding(.trailing, Space.s)
                        }
                    }
                    .frame(height: Metrics.shortcutHeight)
                    .background(Color(hex: "#2a2a2a"))
                    .overlay(alignment: .bottom) {
                        // A started episode: Spotify's thin progress line along the tile's foot.
                        if let f = episodeTile(it).progress {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.white.opacity(0.25))
                                    Rectangle().fill(Palette.accent).frame(width: g.size.width * f)
                                }
                            }
                            .frame(height: 3)
                            .padding(.leading, Metrics.shortcutHeight)
                            .accessibilityElement()
                            .accessibilityLabel("\(Int((f * 100).rounded()))% played")
                            .accessibilityIdentifier("shortcut-progress")
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.s, style: .continuous))
                }
                .buttonStyle(PressScale(scale: 0.97))
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                    Haptics.impact(.medium); app.sheet = .collection(homeBrowseItem(it))
                })
                .accessibilityIdentifier("shortcut")
            }
        }
        .padding(.horizontal, Space.gutter)
    }
}

extension HomeView {
    func episodeTile(_ it: ShelfItem) -> (progress: Double?, isNew: Bool) {
        Self.episodeTile(it, live: app.podcasts.progress[it.id])
    }

    /// An episode tile's progress (0...1, nil when unstarted or finished) and its "new" dot. The
    /// live `podcasts:progress` wins over what Home was built with (desktop magic-d4).
    static func episodeTile(_ it: ShelfItem, live: EpisodeProgress?) -> (progress: Double?, isNew: Bool) {
        guard it.kind == "episode" else { return (nil, false) }
        if let p = live {
            let f: Double? = p.played ? nil : p.positionSecs > 0 ? min(1, max(0, p.fraction)) : nil
            return (f, f == nil && !p.played && it.newEpisode == true)
        }
        let f = it.progress.map { min(1, max(0, $0)) }
        return (f, f == nil && it.newEpisode == true)
    }
}

/// A Home shelf to open as a "Show all" grid.

/// A Home tile as a card the router and sheets understand (Liked Songs folds to `VLLM`).
func homeBrowseItem(_ s: ShelfItem) -> BrowseItem {
    let liked = s.kind == "liked" || HomeStore.key(s.id) == likedPlaylistId
    return BrowseItem(kind: liked ? .playlist : BrowseKind(rawValue: s.kind) ?? .playlist, id: liked ? likedPlaylistId : s.id, title: s.title,
                      subtitle: s.subtitle, thumbnail: s.thumbnail, duration: s.song?.duration, albumId: s.song?.albumId,
                      artistRuns: s.song?.artistRuns, explicit: s.explicit)
}

// MARK: home additions (smart2)

struct MadeForYouShelf: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let cards = app.settings.madeForYou
        if !cards.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Button { app.router.push(.madeForYou) } label: { SectionTitle(title: "Made for you", showAll: true) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("mfy-show-all")
                CardShelf(items: cards.map { BrowseItem(kind: .playlist, id: $0.id, title: $0.title, subtitle: $0.description, thumbnail: $0.thumbnail) })
            }
            .padding(.top, Space.xl)
        }
    }
}

/// Spotify's library line for an album: "Album • Artist" (or "Single • …" / "EP • …"), never the
/// core's repeated type or the year.
func albumSubtitle(_ raw: String?) -> String {
    let parts = (raw ?? "").components(separatedBy: " • ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let types: Set<String> = ["Album", "Single", "EP"]
    let type = parts.first(where: types.contains) ?? "Album"
    let rest = parts.filter { !types.contains($0) && !($0.count == 4 && Int($0) != nil) }
    return rest.isEmpty ? type : "\(type) • \(rest.joined(separator: ", "))"
}
