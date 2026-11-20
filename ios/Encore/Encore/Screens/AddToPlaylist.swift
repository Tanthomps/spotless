// Spotify iOS "Add to playlist" (also its "Saved in" sheet from the like button): a full-height
// sheet with Cancel + title, a white "New playlist" pill, a search field, "Saved in" (Liked Songs and
// the playlists that already hold the song, checked), the other playlists most recently updated
// first, a check circle per row (multi-select), and a "Done" pill that applies every change at once.
import SwiftUI

struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let songs: [SongItem]

    @State private var query = ""
    /// Checked rows: playlist ids, plus `likedPlaylistId` for Liked Songs.
    @State private var selected: Set<String> = []
    @State private var initial: Set<String> = []
    @State private var loaded = false
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var searchFocused: Bool

    private var song: SongItem? { songs.count == 1 ? songs.first : nil }
    private var changed: Bool { selected != initial }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    newPlaylistButton
                        .frame(maxWidth: .infinity)
                        .padding(.top, Space.l)
                        .padding(.bottom, Space.xl)
                    searchField
                        .padding(.horizontal, Space.gutter)
                        .padding(.bottom, Space.l)
                    if !savedIn.isEmpty && query.isEmpty {
                        sectionHeader("Saved in", trailing: "Clear all") {
                            Haptics.selection()
                            selected.removeAll()
                        }
                        ForEach(savedIn) { row($0) }
                        Spacer().frame(height: Space.l)
                    }
                    if membershipUnknown {
                        Text("Couldn't check which playlists already have this song.")
                            .font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                    }
                    if !others.isEmpty {
                        sectionHeader(query.isEmpty ? "Recently updated" : "Playlists")
                        ForEach(others) { row($0) }
                    } else if !query.isEmpty && savedIn.allSatisfy({ !matches($0.title) }) {
                        Text("No playlists match \u{201C}\(query)\u{201D}")
                            .font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                            .frame(maxWidth: .infinity).padding(.top, Space.xxl)
                    }
                }
                .padding(.bottom, 120)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .overlay(alignment: .bottom) { doneBar }
        .background(Palette.base)
        .foregroundStyle(Palette.text)
        .task { await load() }
        .alert("Give your playlist a name", isPresented: $naming) {
            TextField("Playlist name", text: $newName)
                .accessibilityIdentifier("picker-new-name")
            Button("Cancel", role: .cancel) {}
            Button("Create") { createAndAdd() }
        }
    }

    // MARK: pieces

    private var topBar: some View {
        ZStack {
            Text("Add to playlist").font(Typo.font(16, .bold))
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("add-to-playlist")
            HStack {
                Button("Cancel") { dismiss() }
                    .font(Typo.font(16, .regular)).foregroundStyle(Palette.text)
                    .accessibilityIdentifier("picker-cancel")
                Spacer()
            }
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: 56)
    }

    private var newPlaylistButton: some View {
        Button {
            Haptics.impact(.light)
            newName = "My playlist #\(app.library.snapshot.playlists.count + 1)"
            naming = true
        } label: {
            Text("New playlist").font(Typo.font(15, .bold)).foregroundStyle(.black)
                .padding(.horizontal, 28).frame(height: 44)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("picker-new-playlist")
    }

    private var searchField: some View {
        HStack(spacing: Space.s) {
            Icon(name: "magnifying-glass", size: 18).foregroundStyle(Palette.subdued)
            TextField("", text: $query, prompt: Text("Find playlist").foregroundStyle(Palette.subdued))
                .font(Typo.font(14)).focused($searchFocused).submitLabel(.search)
                .tint(Palette.accent)
                .accessibilityLabel("Find playlist")
            if !query.isEmpty {
                Button { query = "" } label: { Icon(name: "x", size: 16).foregroundStyle(Palette.subdued) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.m)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.elevatedHighlight))
    }

    private func sectionHeader(_ title: String, trailing: String? = nil, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(Typo.font(16, .bold)).accessibilityAddTraits(.isHeader)
            Spacer()
            if let trailing, let action {
                Button(trailing, action: action).font(Typo.font(14, .regular)).foregroundStyle(Palette.subdued)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.s)
    }

    private func row(_ r: PickerRow) -> some View {
        let on = selected.contains(r.id)
        return Button {
            Haptics.selection()
            if on { selected.remove(r.id) } else { selected.insert(r.id) }
        } label: {
            HStack(spacing: Space.m) {
                if r.id == likedPlaylistId { LikedCover(size: Metrics.rowArt) } else {
                    ArtImage(url: r.art, px: 160, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(r.title).font(Typo.rowTitle).lineLimit(1)
                    Text(r.subtitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if on {
                    Icon(name: "check-circle", fill: true, size: 26).foregroundStyle(Palette.accent)
                        .transition(Motion.pop)
                } else {
                    Circle().stroke(Palette.subdued, lineWidth: 1.5).frame(width: 22, height: 22).frame(width: 26, height: 26)
                }
            }
            .padding(.horizontal, Space.gutter)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowPress())
        .pulse(on: on)
        .animation(.easeOut(duration: 0.15), value: on)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(r.title), \(r.subtitle)")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("picker-row-\(r.id)")
    }

    private var doneBar: some View {
        Button(action: done) {
            Text("Done").font(Typo.font(16, .bold)).foregroundStyle(.black)
                .padding(.horizontal, 44).frame(height: 48)
                .background(Capsule().fill(changed ? Palette.accent : Color.white))
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("picker-done")
        .padding(.top, 28)
        .padding(.bottom, Space.l)
        .frame(maxWidth: .infinity)
        .background(LinearGradient(colors: [Palette.base.opacity(0), Palette.base], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45))
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false))
    }

    // MARK: data

    struct PickerRow: Identifiable {
        var id: String
        var title: String
        var subtitle: String
        var art: String?
    }

    private var allRows: [PickerRow] {
        let liked = PickerRow(id: likedPlaylistId, title: "Liked Songs",
                              subtitle: app.library.likedIds.count == 1 ? "1 song" : "\(app.library.likedIds.count) songs", art: nil)
        let lib = app.library
        var lists = lib.snapshot.playlists.map {
            (lib.recentsKey($0.id, base: $0.updatedAt), PickerRow(id: $0.id, title: $0.name, subtitle: $0.count == 1 ? "1 song" : "\($0.count) songs", art: $0.cover ?? $0.thumbnail))
        }
        // Signed in: your own playlists on the YouTube account too (not ones you only saved).
        if app.account.signedIn {
            lists += app.account.youtube.editable.map { (lib.recentsKey($0.id), PickerRow(id: $0.id, title: $0.title, subtitle: Self.count($0.subtitle), art: $0.thumbnail)) }
        }
        return [liked] + lists.sorted { $0.0 > $1.0 }.map(\.1)
    }

    /// "6 songs" out of YouTube's library line ("Name • 6 tracks").
    static func count(_ subtitle: String?) -> String {
        guard let m = subtitle?.firstMatch(of: /([\d,.]+)\s*(songs?|tracks?)/), let n = Int(m.1.filter(\.isNumber)) else { return "Playlist" }
        return n == 1 ? "1 song" : "\(n) songs"
    }

    private func matches(_ title: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query.trimmingCharacters(in: .whitespaces))
    }

    /// Rows that held the song when the sheet opened (they stay in this section while toggled).
    private var savedIn: [PickerRow] { allRows.filter { initial.contains($0.id) } }
    private var others: [PickerRow] {
        allRows.filter { (!query.isEmpty || !initial.contains($0.id)) && matches($0.title) }
    }

    /// Couldn't ask which playlists already have the song: the ticks may be missing some.
    @State private var membershipUnknown = false

    private func load() async {
        guard !loaded else { return }
        loaded = true
        var start: Set<String> = []
        if let s = song {
            if app.library.isLiked(s.videoId) { start.insert(likedPlaylistId) }
            if app.account.signedIn { start.formUnion(app.account.youtube.index[s.videoId] ?? []) }
            do { start.formUnion(try await app.core.playlistsContaining(videoId: s.videoId)) } catch {
                // The ticks then only know Liked Songs: say so, so a missing tick isn't trusted.
                membershipUnknown = !FriendlyError.isCancellation(error)
            }
        }
        initial = start
        selected = start
    }

    private func done() {
        let added = selected.subtracting(initial)
        let removed = initial.subtracting(selected)
        dismiss()
        guard !added.isEmpty || !removed.isEmpty else { return }
        Haptics.impact(.light)
        let names = Dictionary(allRows.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        Task { await AddToPlaylistSave.apply(app, songs: songs, added: added, removed: removed, names: names) }
    }

    private func createAndAdd() {
        let n = newName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        dismiss()
        Task { await AddToPlaylistSave.create(app, name: n, songs: songs) }
    }
}

/// The picker's writes. Nothing says "Added" until the core has it: each change is awaited, a
/// refused one is reported with `friendlyError` (and a refused like puts the heart back).
@MainActor
enum AddToPlaylistSave {
    /// Returns true when every change went through.
    @discardableResult
    static func apply(_ app: AppModel, songs: [SongItem], added: Set<String>, removed: Set<String>, names: [String: String]) async -> Bool {
        let ids = songs.map(\.videoId)
        let actions = app.library.actions
        var failure: (error: Error, context: String)?
        func name(_ id: String) -> String { names[id] ?? "the playlist" }
        for id in added.sorted() {
            let e: Error?
            if id == likedPlaylistId {
                e = await firstError(songs) { await app.library.setLikedQuietly($0, true) }
            } else {
                e = await actions.attempt("addToPlaylist") { try await app.core.addToPlaylist(id: id, songs: songs) }
                if e == nil, !isLocalPlaylistId(id) { app.account.youtube.noteAdded(id, videoIds: ids) }
            }
            if let e, failure == nil { failure = (e, "Couldn't add to \(name(id))") }
        }
        for id in removed.sorted() {
            let e: Error?
            if id == likedPlaylistId {
                e = await firstError(songs) { await app.library.setLikedQuietly($0, false) }
            } else {
                e = await actions.attempt("removeFromPlaylist") { try await app.core.removeFromPlaylist(id: id, videoIds: ids) }
                if e == nil, !isLocalPlaylistId(id) { app.account.youtube.noteRemoved(id, videoIds: ids) }
            }
            if let e, failure == nil { failure = (e, "Couldn't remove that from \(name(id))") }
        }
        await app.library.refresh()
        if let failure {
            // More than one change: say the whole save didn't go through, not just the first.
            let many = added.count + removed.count > 1
            app.fail(friendlyError(failure.error, many ? "Couldn't save all your changes" : failure.context))
            return false
        }
        if removed.isEmpty, added.count == 1, let id = added.first {
            app.showToast("Added to \(names[id] ?? "playlist")")
        } else if added.isEmpty, removed.count == 1, let id = removed.first {
            app.showToast("Removed from \(names[id] ?? "playlist")")
        } else {
            app.showToast("Changes saved")
        }
        return true
    }

    /// "New playlist" in the picker: create it, then add the songs. Signed in, it goes on the
    /// YouTube account, as the desktop's New playlist dialog does by default.
    @discardableResult
    static func create(_ app: AppModel, name: String, songs: [SongItem]) async -> Bool {
        let actions = app.library.actions
        var created: (id: String, name: String)?
        let onAccount = app.account.signedIn
        if let e = await actions.attempt("createPlaylist", {
            if onAccount { let r = try await app.account.youtube.create(title: name); created = (r.id, r.title) }
            else { let p = try await app.core.createPlaylist(name: name); created = (p.id, p.name) }
        }) {
            app.fail(friendlyError(e, "Couldn't create the playlist"))
            return false
        }
        guard let pl = created else { return false }
        let e = await actions.attempt("addToPlaylist") { try await app.core.addToPlaylist(id: pl.id, songs: songs) }
        if e == nil, onAccount { app.account.youtube.noteAdded(pl.id, videoIds: songs.map(\.videoId)) }
        await app.library.refresh()
        if let e {
            app.fail(friendlyError(e, "Created \(pl.name), but couldn't add the songs"))
            return false
        }
        app.showToast("Added to \(pl.name)")
        return true
    }

    private static func firstError(_ songs: [SongItem], _ op: (SongItem) async -> Error?) async -> Error? {
        var first: Error?
        for s in songs { if let e = await op(s), first == nil { first = e } }
        return first
    }
}

private struct PickerRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Palette.tinted : .clear)
    }
}
