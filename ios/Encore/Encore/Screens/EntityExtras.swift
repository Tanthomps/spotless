// Stream magic-ib: the parts of the entity pages Spotify adds after the basics. Find in playlist and
// Sort by (gap #25), the "Recommended" footer under your own playlists (gap #4), and the artist
// discography: the chip block on the artist page and the full discography page (gap #26).
import SwiftUI

// MARK: find in playlist + sort

/// Spotify's bar above a playlist's cover, revealed by pulling the page down: a translucent
/// "Find in playlist" field and a "Sort" button, both 36 pt, radius 6.
struct PlaylistFindBar: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onSort: () -> Void

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                Icon(name: "magnifying-glass", size: 16).foregroundStyle(Palette.text)
                TextField("", text: $query, prompt: Text("Find in playlist").foregroundStyle(Palette.text.opacity(0.85)))
                    .font(Typo.font(14, .medium)).foregroundStyle(Palette.text)
                    .focused(focused).submitLabel(.search).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("find-in-playlist")
                if !query.isEmpty {
                    Button { query = "" } label: { Icon(name: "x", size: 14).foregroundStyle(Palette.text).frame(width: 28, height: 28) }
                        .accessibilityLabel("Clear")
                }
            }
            .padding(.leading, Space.s + 2).padding(.trailing, Space.xs)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.white.opacity(0.12)))
            Button(action: onSort) {
                Text("Sort").font(Typo.font(14, .medium)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.m + 2).frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Color.white.opacity(0.12)))
            }
            .buttonStyle(PressScale())
            .accessibilityIdentifier("playlist-sort")
        }
    }
}

/// "Sort by" sheet: the options with an accent check on the current one (the library sort sheet's look).
struct PlaylistSortSheet: View {
    @Environment(\.dismiss) private var dismiss
    let options: [PlaylistViewSort]
    let selected: PlaylistViewSort
    let pick: (PlaylistViewSort) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Sort by").font(Typo.font(16, .bold)).padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.s)
            ForEach(options) { s in
                Button {
                    Haptics.selection()
                    pick(s)
                    dismiss()
                } label: {
                    HStack {
                        Text(s.title).font(Typo.sheetItem).foregroundStyle(s == selected ? Palette.accentText : Palette.text)
                        Spacer()
                        if s == selected { Icon(name: "check", size: 20).foregroundStyle(Palette.accent) }
                    }
                    .padding(.horizontal, Space.gutter).frame(height: 52).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sort-\(s.rawValue)")
                .accessibilityAddTraits(s == selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
        .presentationDetents([.height(CGFloat(options.count) * 52 + 84)])
        .presentationDragIndicator(.visible)
        .presentationBackground { SheetGlass() }
        .presentationCornerRadius(Radius.glassSheet)
    }
}

/// Find in playlist matched nothing (Spotify's wording).
struct FindNoMatch: View {
    let query: String
    var body: some View {
        VStack(spacing: Space.s) {
            Text("Couldn't find \"\(query)\"").font(Typo.font(16, .bold)).multilineTextAlignment(.center)
            Text("Try searching again using a different spelling or keyword.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Space.xxl).padding(.vertical, Space.xxl)
        .accessibilityIdentifier("find-no-match")
    }
}

// MARK: recommended footer

/// "Recommended" under your own playlist: songs that fit it, each with an outline + that adds it
/// (the row leaves the list), and a Refresh pill for the next batch.
struct RecommendedSection: View {
    @Environment(AppModel.self) private var app
    let recs: [Recommendation]
    let loading: Bool
    let onAdd: (Recommendation) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended").font(Typo.font(22, .bold)).accessibilityAddTraits(.isHeader)
                Text(recommendedNote(recs)).font(Typo.font(14)).foregroundStyle(Palette.subdued)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xxl).padding(.bottom, Space.s)
            if loading && recs.isEmpty {
                SkeletonRows(count: 3)
            }
            ForEach(Array(recs.enumerated()), id: \.element.song.videoId) { i, r in
                RecommendedRow(rec: r, onAdd: { onAdd(r) }) {
                    let songs = recs.map(\.song)
                    app.player.play(songs, at: i, context: PlayContext(kind: .song, id: nil, title: "Recommended"))
                }
                .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
            }
            Button(action: onRefresh) {
                Text("Refresh").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.l + 4).frame(height: 32)
                    .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
            }
            .buttonStyle(PressScale())
            .frame(maxWidth: .infinity)
            .padding(.top, Space.l)
            .disabled(loading)
            .accessibilityIdentifier("recommended-refresh")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recommended")
    }
}

/// The Recommended subtitle: what the core seeded the suggestions from.
func recommendedNote(_ recs: [Recommendation]) -> String {
    recs.first?.basis == "listening" ? "Based on what you listen to" : "Based on what's in this playlist"
}

struct RecommendedRow: View {
    @Environment(AppModel.self) private var app
    let rec: Recommendation
    let onAdd: () -> Void
    let onTap: () -> Void

    var body: some View {
        let s = rec.song
        let current = app.player.now?.videoId == s.videoId
        HStack(spacing: Space.m) {
            ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(Typo.rowTitle).foregroundStyle(current ? Palette.accentText : Palette.text).lineLimit(1)
                HStack(spacing: 5) {
                    if s.explicit == true { ExplicitBadge() }
                    Text(s.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Icon(name: "plus-circle", size: 24).foregroundStyle(Palette.subdued).frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(s.title) to this playlist")
            .accessibilityIdentifier("recommended-add")
        }
        .padding(.leading, Space.gutter).padding(.trailing, Space.gutter - 10)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.impact(.medium)
            app.sheet = .track(s, context: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recommended-row")
    }
}

// MARK: discography

/// One release: 80 pt art, title 16/700 (2 lines), "2013 • Album".
struct DiscographyRow: View {
    @Environment(AppModel.self) private var app
    let item: BrowseItem
    let line: String

    var body: some View {
        Button { app.router.open(item) } label: {
            HStack(spacing: Space.m) {
                ArtImage(url: item.thumbnail, px: 240, radius: Radius.xs).frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(Typo.font(16, .bold)).foregroundStyle(Palette.text).lineLimit(2).multilineTextAlignment(.leading)
                    Text(line).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.gutter).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
            Haptics.impact(.medium)
            app.sheet = .collection(item)
        })
        .accessibilityIdentifier("release-row")
    }
}

/// The artist page's Discography block: chips (Popular releases · Albums · Singles and EPs), four
/// releases, then "See discography".
struct DiscographyBlock: View {
    let disco: Discography
    @Binding var filter: Discography.Filter
    let seeAll: () -> Void

    var body: some View {
        let current = disco.filters.contains(filter) ? filter : (disco.filters.first ?? .popular)
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Discography").font(Typo.font(22, .bold)).padding(.horizontal, Space.gutter).accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    ForEach(disco.filters) { f in
                        Chip(title: f.title, selected: f == current) { withAnimation(Motion.quick) { filter = f } }
                            .accessibilityIdentifier("disco-chip-\(f.rawValue)")
                            .accessibilityAddTraits(f == current ? .isSelected : [])
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            VStack(spacing: 0) {
                ForEach(disco.items(current).prefix(4)) { r in DiscographyRow(item: r.item, line: r.line) }
            }
            Button(action: seeAll) {
                Text("See discography").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.l + 4).frame(height: 32)
                    .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
            }
            .buttonStyle(PressScale())
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("see-discography")
        }
        .padding(.top, Space.xl)
    }
}

/// Spotify's full discography page: All · Albums · Singles and EPs · Compilations, newest first.
struct DiscographyView: View {
    @Environment(AppModel.self) private var app
    let artistId: String
    var initial: Discography.Filter?
    @State private var disco: Discography?
    @State private var failed = false
    @State private var attempt = 0
    /// nil: All.
    @State private var filter: Discography.Filter?
    @State private var started = false

    private static let pageFilters: [Discography.Filter] = [.albums, .singles, .compilations]

    private var rows: [Discography.Release] {
        guard let disco else { return [] }
        return filter.map(disco.items) ?? disco.all
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                BackButton()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Discography").font(Typo.font(20, .bold))
                    if let name = disco?.artistName, !name.isEmpty { Text(name).font(Typo.meta).foregroundStyle(Palette.subdued) }
                }
                Spacer()
            }
            .padding(.horizontal, Space.s + 2)
            .frame(height: 52)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.s) {
                    Chip(title: "All", selected: filter == nil) { withAnimation(Motion.quick) { filter = nil } }
                        .accessibilityIdentifier("disco-chip-all")
                    ForEach(Self.pageFilters.filter { !(disco?.items($0).isEmpty ?? true) }) { f in
                        Chip(title: f.title, selected: filter == f) { withAnimation(Motion.quick) { filter = filter == f ? nil : f } }
                            .accessibilityIdentifier("disco-chip-\(f.rawValue)")
                    }
                }
                .padding(.horizontal, Space.gutter)
            }
            .padding(.vertical, Space.m)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if disco == nil { EntityLoadState(failed: failed) { failed = false; attempt += 1 } }
                    ForEach(rows) { r in DiscographyRow(item: r.item, line: r.line) }
                }
            }
        }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("discography-page")
        .task(id: attempt) {
            if !started { started = true; filter = initial == .popular ? nil : initial }
            disco = try? await app.core.artistDiscography(id: artistId)
            failed = disco == nil
        }
    }
}
