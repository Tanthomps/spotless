// A Home shelf's "Show all" page: Spotify iOS opens every shelf as a two-column grid of its cards
// under a back bar with the shelf's title. Reads the shelf from `HomeStore`, so it stays current
// (offline that's the core's offline Home).
import SwiftUI

struct ShelfGridView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    let title: String
    /// A podcast category (`podcat:<genre>`): its shows, from the core (`podcast_category`).
    @State private var category: [ShelfItem]?
    @State private var failed = false
    @State private var attempt = 0
    /// A category page (podcasts, audiobook genre) fetched from the core, not read from Home.
    private var fetched: Bool { id.hasPrefix("podcat:") || Self.audiobookGenre(id) != nil }

    private var items: [ShelfItem] {
        if let category { return category }
        return app.home.shelf(id)?.items ?? []
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button { dismiss() } label: { Icon(name: "caret-left", size: 22).frame(width: 34, height: 34) }
                    .accessibilityLabel("Back").accessibilityIdentifier("back")
                Text(title).font(Typo.font(18, .bold)).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.s)
            GeometryReader { g in
                let card = floor((g.size.width - Space.gutter * 2 - Space.l) / 2)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.fixed(card), spacing: Space.l, alignment: .top), GridItem(.fixed(card), alignment: .top)],
                              spacing: Space.xl) {
                        ForEach(list) { it in
                            Button { tap(it, in: list) } label: {
                                MediaCard(title: it.title, subtitle: it.subtitle, thumbnail: it.thumbnail, circle: it.kind == "artist",
                                          size: card, liked: it.kind == "liked" || HomeStore.key(it.id) == likedPlaylistId,
                                          fallback: ArtRef(id: it.id, title: it.title))
                                    .frame(width: card, alignment: it.kind == "artist" ? .center : .leading)
                            }
                            .buttonStyle(PressScale())
                            .simultaneousGesture(LongPressGesture(minimumDuration: 0.45).onEnded { _ in
                                Haptics.impact(.medium)
                                let b = homeBrowseItem(it)
                                app.sheet = b.kind == .song ? .track(b.asSong, context: nil) : .collection(b)
                            })
                            .accessibilityIdentifier("shelf-grid-item")
                        }
                    }
                    .padding(.horizontal, Space.gutter)
                    .padding(.top, Space.s)
                    if fetched && category == nil {
                        EntityLoadState(failed: failed) { failed = false; attempt += 1 }
                    } else if list.isEmpty {
                        Text("Nothing here right now").font(Typo.font(16, .bold)).padding(.top, 60)
                    }
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf-grid")
        .task(id: attempt) {
            // stream: audiobooks — a genre tile (`abgenre:<subject>`) or an audiobook shelf's
            // Show all: that genre's whole list (`audiobook_genre`).
            do {
                if let genre = Self.audiobookGenre(id) {
                    category = try await app.core.audiobookGenre(genre: genre).map {
                        ShelfItem(kind: "audiobook", id: $0.id, title: $0.title, subtitle: $0.author, thumbnail: $0.thumbnail, explicit: false)
                    }
                    return
                }
                guard id.hasPrefix("podcat:") else { return }
                category = try await app.core.podcastCategory(genre: String(id.dropFirst("podcat:".count)))
            } catch {
                if !FriendlyError.isCancellation(error) { failed = true }
            }
        }
    }

    static func audiobookGenre(_ id: String) -> String? {
        if id == "ab_popular" { return "popular" }
        for p in ["abgenre:", "ab_genre:"] where id.hasPrefix(p) { return String(id.dropFirst(p.count)) }
        return nil
    }

    private func tap(_ it: ShelfItem, in list: [ShelfItem]) {
        let b = homeBrowseItem(it)
        if b.kind == .song {
            let songs = list.filter { $0.kind == "song" }.map { homeBrowseItem($0).asSong }
            app.player.play(songs, at: songs.firstIndex { $0.videoId == it.id } ?? 0, context: PlayContext(kind: .song, id: nil, title: title))
        } else {
            app.router.open(b)
        }
    }
}
