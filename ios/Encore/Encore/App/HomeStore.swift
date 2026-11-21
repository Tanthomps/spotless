// Home's shelves as a store (not view state), so they can move the moment you play something,
// back a shelf's "Show all" page; offline the core builds them from downloads. The pure helpers are what the tests pin.
import SwiftUI
import Observation

@MainActor @Observable
final class HomeStore {
    let core: CoreClient
    var shelves: [Shelf] = []
    var loadedAt = Date.distantPast
    /// stream: home-tiles-pods — the Podcasts chip's shelves (`podcast_home`).
    var podcastShelves: [Shelf] = []
    /// stream: audiobooks — the Audiobooks chip (`audiobook_home`).
    var audiobookShelves: [Shelf] = []

    init(core: CoreClient) { self.core = core }

    /// A `smart_home` answer came back (even an empty one): Home stops showing skeletons.
    var loaded = false
    /// The last try threw with nothing on screen: Home shows the error with Reload.
    var failed = false
    /// The last `smart_home` call threw (shelves may still be on screen).
    @ObservationIgnored var lastFetchFailed = false

    /// Loads `smart_home`. Online it retries with the desktop's backoff (2 s doubling, capped at
    /// 30 s) until YouTube's own shelves are in: a Home of only local shelves or moods means
    /// YouTube's part failed (bot wall), and if it failed outright no `home-changed` follows.
    /// Offline the core builds Home from your downloads (`offline_home`): one try, no network.
    func load(isOffline: @escaping @MainActor () -> Bool) async {
        if isOffline() {
            await fetch(keepNonEmpty: false)
            return
        }
        var delay: UInt64 = 2_000_000_000
        for _ in 0..<6 {
            await fetch(keepNonEmpty: true)
            if Self.complete(shelves) || Task.isCancelled || isOffline() { return }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 30_000_000_000)
        }
    }

    /// One `smart_home` call. Online an empty answer keeps what's on screen (a partial reload).
    private func fetch(keepNonEmpty: Bool) async {
        do {
            let got = try await core.smartHome()
            if !got.isEmpty || !keepNonEmpty || shelves.isEmpty { shelves = got; loadedAt = Date() }
            loaded = true
            failed = false
            lastFetchFailed = false
        } catch {
            failed = shelves.isEmpty
            lastFetchFailed = !FriendlyError.isCancellation(error)
        }
    }

    /// A context just started: first shortcut tile, now. The core's `home-changed`
    /// (`reason: "played"`) follows and the reload already has the same order.
    func touch(_ item: ShelfItem) {
        guard !shelves.isEmpty else { return }
        withAnimation(Motion.spring) { shelves = Self.bumped(shelves, context: item) }
    }

    /// A song just started: front of "Recently played" (when that shelf lists songs).
    func touchSong(_ song: SongItem) {
        guard !shelves.isEmpty else { return }
        shelves = Self.bumped(shelves, song: song)
    }

    func shelf(_ id: String) -> Shelf? { (shelves + podcastShelves + audiobookShelves).first { $0.id == id } }

    /// stream: audiobooks — the Audiobooks chip: one try; a failure keeps what was there.
    func loadAudiobooks() async {
        do {
            let got = try await core.audiobookHome()
            if !got.isEmpty { audiobookShelves = got }
            audiobooksLoaded = true; audiobooksFailed = false
        } catch { if !FriendlyError.isCancellation(error) { audiobooksFailed = audiobookShelves.isEmpty } }
    }
    var audiobooksLoaded = false
    var audiobooksFailed = false
    var podcastsLoaded = false
    var podcastsFailed = false

    /// The Podcasts chip: never empty in the core (fixed category tiles stand in), so one try.
    func loadPodcasts() async {
        do {
            let got = try await core.podcastHome()
            if !got.isEmpty { podcastShelves = got }
            podcastsLoaded = true; podcastsFailed = false
        } catch { if !FriendlyError.isCancellation(error) { podcastsFailed = podcastShelves.isEmpty } }
    }

    // MARK: pure helpers

    /// Liked Songs is "liked" in the core's shortcuts and `VLLM` everywhere else.
    nonisolated static func key(_ id: String) -> String { id == "liked" ? likedPlaylistId : id }

    nonisolated static func complete(_ shelves: [Shelf]) -> Bool {
        shelves.contains { $0.source == "youtube" && ($0.layout == .cards || $0.layout == .songs) }
    }

    /// The shortcut tile for a started context; nil for loose plays (search results, single songs,
    /// radios) that Spotify's grid doesn't show.
    nonisolated static func shortcut(for ctx: PlayContext, thumbnail: String?) -> ShelfItem? {
        guard let id = ctx.id, !id.isEmpty else { return nil }
        let kind: String
        switch ctx.kind {
        case .liked: kind = "liked"
        case .playlist: kind = key(id) == likedPlaylistId ? "liked" : "playlist"
        case .album: kind = "album"
        case .artist: kind = "artist"
        case .dailyMix: kind = "daily_mix"
        case .audiobook: kind = "audiobook" // stream: audiobooks
        case .radio, .search, .song: return nil
        }
        if kind == "liked" { return ShelfItem(kind: "liked", id: likedPlaylistId, title: "Liked Songs", explicit: false) }
        return ShelfItem(kind: kind, id: id, title: ctx.title, thumbnail: thumbnail, explicit: false)
    }

    /// Moves (or adds) `context` to the first shortcut tile (after Liked Songs), keeping at most `limit` tiles. The
    /// core's own tile wins when it has one (its title and art are canonical).
    nonisolated static func bumped(_ shelves: [Shelf], context: ShelfItem, limit: Int = 8) -> [Shelf] {
        var out = shelves
        let k = key(context.id)
        if let i = out.firstIndex(where: { $0.layout == .shortcuts }) {
            var items = out[i].items
            var moved = items.firstIndex { key($0.id) == k }.map { items.remove(at: $0) } ?? context
            if moved.thumbnail == nil { moved.thumbnail = context.thumbnail }
            // Liked Songs stays pinned to the first tile (the core's order); the rest follow it.
            let at = k != likedPlaylistId && items.first.map({ key($0.id) == likedPlaylistId }) == true ? 1 : 0
            items.insert(moved, at: at)
            out[i].items = Array(items.prefix(limit))
        } else {
            out.insert(Shelf(id: "shortcuts", title: "", layout: .shortcuts, source: "local", items: [context]), at: 0)
        }
        return out
    }

    /// Moves (or adds) `song` to the front of a song "Recently played" shelf.
    nonisolated static func bumped(_ shelves: [Shelf], song: SongItem, limit: Int = 20) -> [Shelf] {
        var out = shelves
        guard let i = out.firstIndex(where: { $0.id == "recently_played" }),
              out[i].items.contains(where: { $0.kind == "song" }) else { return shelves }
        var items = out[i].items
        let moved = items.firstIndex { $0.id == song.videoId }.map { items.remove(at: $0) }
            ?? ShelfItem(kind: "song", id: song.videoId, title: song.title, subtitle: song.artists, thumbnail: song.thumbnail,
                         explicit: song.explicit ?? false, song: song)
        items.insert(moved, at: 0)
        out[i].items = Array(items.prefix(limit))
        return out
    }

    nonisolated static let podcastKinds: Set<String> = ["podcast", "episode", "show"]

    /// The "Music" chip: no podcast or episode tiles anywhere, and no shelf left empty by that.
    nonisolated static func musicOnly(_ shelves: [Shelf]) -> [Shelf] {
        shelves.compactMap { s in
            if s.layout == .notice { return s }
            var s = s
            s.items = s.items.filter { !podcastKinds.contains($0.kind) }
            let podcastShelf = s.id.contains("podcast") || s.id.contains("episode")
            return s.items.isEmpty || podcastShelf ? nil : s
        }
    }

}
