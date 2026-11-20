// Stream magic-ib (I-B2): the playlist page's smarts, as on the desktop (docs/streams/magic-d3.md).
// - Genre and mood chips on Liked Songs (`smart_tags_liked`): a chip filters the list, and Play
//   plays the filtered set.
// - Enhance on your own playlists and Liked Songs (`enhance_*`): a sparkle pill that mixes in one
//   suggestion after every 2 songs, each with + (keep: add it) and − (not for me). It is hidden
//   while a find query or a chip is active.
// - Paging for long YouTube playlists (`get_playlist_more`): the next page loads near the end.
import SwiftUI

/// One row of the playlist list: a song of the queue Play would start (`index` into `queue`).
struct PlaylistRow: Identifiable {
    var index: Int
    var song: SongItem
    var suggestion: Bool
    var id: Int { index }
}

@MainActor @Observable
final class PlaylistSmarts {
    // chips (Liked Songs)
    var chips: LikedChips = .empty
    var chip: String?
    // Enhance
    var enhance: EnhanceState?
    var enhanceBusy = false
    // paging
    var continuation: String?
    var loadingMore = false
    /// The next page (or finding it) failed: the list ends in "Couldn't load more songs · Try again".
    var moreFailed = false
    /// Suggestions being added right now (a second tap on + does nothing).
    var keeping: Set<String> = []

    /// Enhance mixes in one suggestion after every 2 songs (the core's `interleave`).
    nonisolated static let enhanceEvery = 2

    /// The songs a chip keeps (all of them without a chip).
    func base(_ ordered: [SongItem]) -> [SongItem] {
        guard let chip, let c = chips.chips.first(where: { $0.label == chip }) else { return ordered }
        let ids = Set(c.videoIds)
        return ordered.filter { ids.contains($0.videoId) }
    }

    /// Enhance shows (and plays) its suggestions only on the plain list.
    func enhanceActive(finding: Bool) -> Bool { enhance?.on == true && !(enhance?.recs.isEmpty ?? true) && chip == nil && !finding }

    /// What Play queues: the (chip-filtered) list, with Enhance's suggestions mixed in when active.
    func queue(_ ordered: [SongItem], finding: Bool) -> [SongItem] {
        let b = base(ordered)
        guard enhanceActive(finding: finding), let recs = enhance?.recs else { return b }
        return Self.interleave(b, recs)
    }

    /// The core's `smartshuffle::interleave`: never a suggestion after the last song.
    nonisolated static func interleave<T>(_ songs: [T], _ recs: [T], every: Int = enhanceEvery) -> [T] {
        var out: [T] = []
        var r = recs.makeIterator()
        for (i, s) in songs.enumerated() {
            out.append(s)
            if (i + 1) % every == 0, i + 1 < songs.count, let x = r.next() { out.append(x) }
        }
        return out
    }

    /// The rows on screen: the queue, filtered by the find query (suggestions are never filtered out,
    /// but they only show without a query).
    func rows(_ ordered: [SongItem], query: String) -> [PlaylistRow] {
        let finding = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let q = queue(ordered, finding: finding)
        let recIds = enhanceActive(finding: finding) ? Set(enhance?.recs.map(\.videoId) ?? []) : []
        return q.enumerated().compactMap { i, s in
            let sug = recIds.contains(s.videoId)
            return sug || matchSong(s, query) ? PlaylistRow(index: i, song: s, suggestion: sug) : nil
        }
    }

    // MARK: loading

    /// Liked Songs' chips; while the core is still tagging (done < total), look again every few seconds.
    func loadChips(_ app: AppModel) async {
        while !Task.isCancelled {
            if let c = try? await app.core.smartTagsLiked() {
                chips = c
                if let chip, !c.chips.contains(where: { $0.label == chip }) { self.chip = nil }
                if c.done >= c.total { return }
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    func loadEnhance(_ app: AppModel, id: String) async {
        enhance = try? await app.core.enhanceState(playlistId: id)
    }

    func toggleEnhance(_ app: AppModel, id: String, length: Int) async {
        guard !enhanceBusy else { return }
        let on = !(enhance?.on ?? false)
        enhanceBusy = true
        defer { enhanceBusy = false }
        do {
            enhance = try await app.core.enhanceSet(playlistId: id, on: on, len: length)
            Haptics.impact(.light)
            app.showToast(on ? "Enhanced with recommendations" : "Enhance off")
        } catch {
            app.showToast("Couldn't enhance this playlist. Try again.")
        }
    }

    /// + on a suggestion: it joins the playlist (Liked Songs: it is liked) and stops being a suggestion.
    func keep(_ app: AppModel, id: String, song: SongItem, liked: Bool, title: String) async {
        guard !keeping.contains(song.videoId) else { return }
        keeping.insert(song.videoId)
        defer { keeping.remove(song.videoId) }
        do {
            if liked { app.toggleLike(song) } else { try await app.core.addToPlaylist(id: id, songs: [song]) }
            enhance = try await app.core.enhanceKeep(playlistId: id, videoId: song.videoId)
            if !liked { app.showToast("Added to \(title)") }
        } catch {
            app.showToast("Couldn't add that song. Try again.")
        }
    }

    /// − on a suggestion: "not for me" (a taste signal), and it leaves.
    func remove(_ app: AppModel, id: String, song: SongItem) async {
        do { enhance = try await app.core.enhanceRemove(playlistId: id, videoId: song.videoId) } catch {
            app.fail(friendlyError(error, "Couldn't remove that suggestion"))
        }
    }

    /// A long YouTube playlist: find the first page's continuation (only worth asking once the page is full).
    func loadContinuation(_ app: AppModel, id: String, count: Int) async {
        guard count >= 100 else { continuation = nil; return }
        do { continuation = try await app.core.playlistContinuation(id: id); moreFailed = false } catch {
            if !FriendlyError.isCancellation(error) { moreFailed = true }
        }
    }

    /// The next page, appended to `items`.
    func loadMore(_ app: AppModel, into items: inout [SongItem]) async {
        guard let token = continuation, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let more: PlaylistMore
        do { more = try await app.core.playlistMore(token: token); moreFailed = false } catch {
            if !FriendlyError.isCancellation(error) { moreFailed = true }
            return
        }
        let have = Set(items.map(\.videoId))
        items += more.items.filter { !have.contains($0.videoId) }
        continuation = more.continuation
    }
}

// MARK: views

/// Liked Songs' chips under the action row; with one picked, the others fold away behind an ✕.
struct SmartChipsBar: View {
    let chips: [SmartChip]
    @Binding var selected: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s) {
                if selected != nil {
                    Button { withAnimation(Motion.quick) { selected = nil } } label: {
                        Icon(name: "x", size: 16).frame(width: Metrics.chipHeight, height: Metrics.chipHeight)
                            .background(Circle().fill(Color(hex: "#2a2a2a")))
                    }
                    .accessibilityLabel("Clear filter")
                    .accessibilityIdentifier("smart-chip-clear")
                }
                ForEach(chips.filter { selected == nil || $0.label == selected }) { c in
                    Chip(title: c.label, selected: selected == c.label) {
                        withAnimation(Motion.quick) { selected = selected == c.label ? nil : c.label }
                        Haptics.selection()
                    }
                    .accessibilityIdentifier("smart-chip")
                    .accessibilityAddTraits(selected == c.label ? .isSelected : [])
                }
            }
            .padding(.horizontal, Space.gutter)
        }
        .padding(.bottom, Space.s)
    }
}

/// The Enhance pill in the action row: sparkle + "Enhance", accent when on.
struct EnhancePill: View {
    let on: Bool
    let busy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy { ProgressView().controlSize(.mini).tint(on ? .black : Palette.text) } else {
                    Icon(name: "sparkle", fill: on, size: 14)
                }
                Text("Enhance").font(Typo.font(13, .bold))
            }
            .foregroundStyle(on ? Color.black : Palette.text)
            .padding(.horizontal, 12).frame(height: 30)
            .background(Capsule().fill(on ? Palette.accent : Color.clear))
            .overlay(Capsule().stroke(on ? Color.clear : Palette.muted, lineWidth: 1))
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(on ? "Turn off Enhance" : "Enhance")
        .accessibilityIdentifier("enhance")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// An Enhance suggestion between the songs: sparkle before the artist, then + and −.
struct EnhanceSuggestionRow: View {
    @Environment(AppModel.self) private var app
    let song: SongItem
    let onAdd: () -> Void
    let onRemove: () -> Void
    let onTap: () -> Void

    var body: some View {
        let current = app.player.now?.videoId == song.videoId
        HStack(spacing: Space.m) {
            ArtImage(url: song.thumbnail, px: 144, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(song.title).font(Typo.rowTitle).foregroundStyle(current ? Palette.accentText : Palette.text).lineLimit(1)
                HStack(spacing: 5) {
                    Icon(name: "sparkle", fill: true, size: 12).foregroundStyle(Palette.accent)
                    Text(song.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Icon(name: "minus-circle", size: 24).foregroundStyle(Palette.subdued).frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove suggestion \(song.title)")
            .accessibilityIdentifier("enhance-remove")
            Button(action: onAdd) {
                Icon(name: "plus-circle", size: 24).foregroundStyle(Palette.subdued).frame(width: 40, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(song.title)")
            .accessibilityIdentifier("enhance-add")
        }
        .padding(.leading, Space.gutter).padding(.trailing, Space.gutter - 8)
        .frame(height: Metrics.rowHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.4) {
            Haptics.impact(.medium)
            app.sheet = .track(song, context: nil)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("enhance-row")
    }
}
