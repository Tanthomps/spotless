// Own playlists (Spotify iOS): "Edit playlist" (change image, rename, description, Public for a
// YouTube playlist, reorder, remove rows), "Add
// to this playlist" (search and add), and "Delete playlist" with Undo. Every change goes through the
// core (`set_playlist_cover` / `lib_playlist_update` / `_set_order` / `_remove` / `_add` /
// `_delete` / `_restore`).
import PhotosUI
import SwiftUI

/// Edit playlist: name field, rows with drag handles and delete, Cancel / Save.
struct EditPlaylistSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var name = ""
    @State private var originalName = ""
    @State private var desc = ""
    @State private var originalDesc = ""
    /// A YouTube playlist's visibility (nil: not one, or not known).
    @State private var isPublic = false
    @State private var originalPublic: Bool?
    @State private var rows: [PlaylistEntry] = []
    @State private var original: [Int64] = []
    @State private var loaded = false
    /// Change image: a picked photo (saved on Save), or `removeCover` to drop the custom one.
    @State private var pick: PhotosPickerItem?
    @State private var picked: UIImage?
    @State private var removeCover = false
    @State private var imageMenu = false
    @State private var pickerOpen = false
    @State private var loadFailed = false
    @State private var attempt = 0
    @State private var saving = false
    @State private var confirmDiscard = false

    /// Anything to lose if the sheet closed now.
    private var changed: Bool {
        guard loaded else { return false }
        return name != originalName || desc != originalDesc || picked != nil || removeCover
            || (originalPublic.map { $0 != isPublic } ?? false) || rows.map(\.rowId) != original
    }

    private var meta: LibPlaylist? { app.library.snapshot.playlists.first { $0.id == id } }
    /// A playlist of yours on the YouTube account (rows are `setVideoId`s there, edits go to YouTube).
    private var isAccount: Bool { !isLocalPlaylistId(id) }
    @State private var accountPage: PlaylistPage?
    private var savedCover: String? { meta?.cover ?? accountPage?.cover }
    private var thumbnail: String? { meta?.thumbnail ?? accountPage?.thumbnail }
    private var hasCustomCover: Bool { picked != nil || (savedCover != nil && !removeCover) }

    var body: some View {
        NavigationStack {
            List {
                if loadFailed {
                    EntityLoadState(failed: true) { loadFailed = false; attempt += 1 }
                        .listRowBackground(Palette.sheet).listRowSeparator(.hidden)
                } else if !loaded {
                    SkeletonRows(count: 4).listRowBackground(Palette.sheet).listRowSeparator(.hidden)
                }
                Section {
                    coverEditor
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Palette.sheet)
                        .listRowSeparator(.hidden)
                    TextField("Playlist name", text: $name)
                        .font(Typo.font(22, .bold))
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("edit-name")
                        .listRowBackground(Palette.sheet)
                    TextField("Add an optional description", text: $desc, axis: .vertical)
                        .font(Typo.font(14))
                        .lineLimit(1...4)
                        .onChange(of: desc) { _, d in if d.count > Self.descMax { desc = String(d.prefix(Self.descMax)) } }
                        .accessibilityLabel("Description")
                        .accessibilityIdentifier("edit-description")
                        .listRowBackground(Palette.sheet)
                    if originalPublic != nil {
                        Toggle(isOn: $isPublic) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Public").font(Typo.font(16))
                                Text(isPublic ? "Anyone can find it and play it on YouTube Music." : "Only you can see it.")
                                    .font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            }
                        }
                        .tint(Palette.accent)
                        .accessibilityIdentifier("edit-public")
                        .listRowBackground(Palette.sheet)
                    }
                }
                Section {
                    ForEach(rows) { r in
                        HStack(spacing: Space.m) {
                            ArtImage(url: r.song.thumbnail, px: 120, radius: Radius.xs).frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.song.title).font(Typo.rowTitle).lineLimit(1)
                                Text(r.song.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("edit-row")
                        .listRowBackground(Palette.sheet)
                    }
                    .onMove { rows.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { rows.remove(atOffsets: $0) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if changed { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Save", action: save).bold().disabled(!loaded || name.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityIdentifier("edit-save")
                    }
                }
            }
        }
        .foregroundStyle(Palette.text)
        .tint(Palette.text)
        // A swipe down can't throw edits away; Cancel asks first.
        .interactiveDismissDisabled(changed || saving)
        .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .photosPicker(isPresented: $pickerOpen, selection: $pick, matching: .images)
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    picked = img; removeCover = false
                } else {
                    app.showToast("Couldn't open that photo")
                }
                pick = nil
            }
        }
        .confirmationDialog("Change image", isPresented: $imageMenu) {
            Button("Choose photo") { pickerOpen = true }
            if hasCustomCover { Button("Remove photo", role: .destructive) { picked = nil; removeCover = true } }
        }
        .task(id: attempt) {
            if isAccount {
                let page: PlaylistPage
                do { page = try await app.core.getPlaylist(id: id) } catch {
                    if !FriendlyError.isCancellation(error) { loadFailed = true }
                    return
                }
                accountPage = page
                rows = page.items.enumerated().map { PlaylistEntry(rowId: Int64($0), position: Int64($0), addedAt: 0, song: $1) }
                originalName = page.title ?? ""
                originalDesc = page.description ?? ""
                // Visibility is YouTube's, and only yours to change.
                if page.owned, let p = page.privacy { originalPublic = p == "PUBLIC"; isPublic = p == "PUBLIC" }
            } else {
                do { rows = try await app.core.playlistEntries(id: id) } catch {
                    if !FriendlyError.isCancellation(error) { loadFailed = true }
                    return
                }
                originalName = meta?.name ?? ""
                originalDesc = meta?.description ?? ""
            }
            original = rows.map(\.rowId)
            name = originalName
            desc = originalDesc
            loaded = true
        }
    }

    /// The cover with "Change image" under it (Spotify's Edit playlist header).
    private var coverEditor: some View {
        Button { imageMenu = true } label: {
            VStack(spacing: Space.s) {
                Group {
                    if let picked { Image(uiImage: picked).resizable().aspectRatio(contentMode: .fill) }
                    else if let c = removeCover ? nil : savedCover { ArtImage(url: c, px: 480, radius: 0) }
                    else if let four = MosaicCover.covers(rows.map(\.song)) { MosaicCover(urls: four) }
                    else { ArtImage(url: thumbnail, px: 480, radius: 0) }
                }
                .frame(width: 140, height: 140)
                .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)
                Text("Change image").font(Typo.font(13, .bold)).foregroundStyle(Palette.text)
            }
            .padding(.vertical, Space.s)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("edit-change-image")
    }

    static let descMax = 300

    /// Saves step by step, then closes. A failed step keeps the sheet open with the edits still in it
    /// (steps that already went through become the new baseline, so Save again only retries the rest).
    private func save() {
        guard !saving else { return }
        let newName = name.trimmingCharacters(in: .whitespaces)
        let newDesc = desc.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChange = newName != originalName ? newName : nil
        let descChange = newDesc != originalDesc ? newDesc : nil
        let publicChange = originalPublic.flatMap { $0 != isPublic ? isPublic : nil }
        let kept = rows.map(\.rowId)
        let removed = original.filter { !kept.contains($0) }
        let reordered = kept != original.filter { kept.contains($0) }
        let dropCover = removeCover && picked == nil && savedCover != nil
        // An account playlist's rows were numbered by position when loaded: back to its songs.
        let setIds = Dictionary(uniqueKeysWithValues: (accountPage?.items ?? []).enumerated().map { (Int64($0), $1) })
        saving = true
        Task {
            defer { saving = false }
            var step = "the image"
            do {
                if let picked, let cover = Self.coverFile(picked) {
                    defer { try? FileManager.default.removeItem(at: cover) }
                    _ = try await app.core.setPlaylistCover(playlistId: id, path: cover.path)
                    self.picked = nil
                } else if dropCover {
                    _ = try await app.core.setPlaylistCover(playlistId: id, path: nil)
                    removeCover = false
                }
                step = "the name and description"
                if isAccount, let yt = app.core as? YouTubeLibraryClient {
                    if nameChange != nil || descChange != nil || publicChange != nil {
                        try await yt.editPlaylistDetails(playlistId: id, name: nameChange, description: descChange, public: publicChange)
                    }
                    if let nameChange { app.account.youtube.renamed(id, to: nameChange) }
                } else if nameChange != nil || descChange != nil {
                    try await app.core.updatePlaylist(id: id, name: nameChange, description: descChange)
                }
                originalName = newName; originalDesc = newDesc
                if publicChange != nil { originalPublic = isPublic }
                step = "the removed songs"
                if isAccount, let yt = app.core as? YouTubeLibraryClient {
                    let gone = removed.compactMap { setIds[$0] }
                    let tracks = gone.compactMap { s in s.setVideoId.map { (s.videoId, $0) } }
                    if !tracks.isEmpty {
                        try await yt.removeManyFromPlaylist(playlistId: id, tracks: tracks)
                        app.account.youtube.noteRemoved(id, videoIds: gone.map(\.videoId))
                    }
                    original = original.filter { kept.contains($0) }
                    step = "the new order"
                    let set = { (ids: [Int64]) in ids.compactMap { setIds[$0]?.setVideoId } }
                    if reordered { try await yt.reorderYouTubePlaylist(id, from: set(original), to: set(kept)) }
                } else {
                    if !removed.isEmpty { try await app.core.removeFromPlaylist(id: id, rowIds: removed) }
                    original = original.filter { kept.contains($0) }
                    step = "the new order"
                    if reordered { try await app.core.setPlaylistOrder(id: id, rowIds: kept) }
                }
                original = kept
            } catch {
                app.fail(friendlyError(error, "Couldn't save \(step). Your edits are still here."))
                await app.library.refresh()
                return
            }
            dismiss()
            app.showToast("Playlist saved")
            await app.library.refresh()
        }
    }
}

extension EditPlaylistSheet {
    /// A picked photo as the JPEG the core copies in (`set_playlist_cover` takes JPEG or PNG under
    /// 8 MB): square-cropped from the centre and at most 1000 px, like Spotify's own crop.
    static func coverFile(_ image: UIImage) -> URL? {
        let side = min(image.size.width, image.size.height)
        guard side > 0 else { return nil }
        let out = min(1000, side)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: out, height: out), format: fmt).image { _ in
            let scale = out / side
            let w = image.size.width * scale, h = image.size.height * scale
            image.draw(in: CGRect(x: (out - w) / 2, y: (out - h) / 2, width: w, height: h))
        }
        guard let data = square.jpegData(compressionQuality: 0.85) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).jpg")
        do { try data.write(to: url) } catch { return nil }
        return url
    }
}

/// "Add to this playlist": a search sheet whose song rows have a + button. Before you type it
/// shows Recommended songs (Spotify): the core seeds them from the playlist, or from your
/// listening when the playlist is still empty.
struct AddSongsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    let name: String
    @State private var query = ""
    @State private var results: [SongItem] = []
    /// The query `results` answer (nil: none yet), and whether the last search failed.
    @State private var resultsFor: String?
    @State private var searchFailed = false
    @State private var searchAttempt = 0
    @State private var added: Set<String> = []
    @State private var recs: [Recommendation] = []
    @State private var recsBatch = 0
    @State private var recsLoading = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Add to this playlist").font(Typo.font(16, .bold))
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.font(Typo.font(15, .bold)).accessibilityIdentifier("add-done")
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.top, Space.l)
            HStack(spacing: Space.s) {
                Icon(name: "magnifying-glass", size: 20)
                TextField("", text: $query, prompt: Text("Search").foregroundStyle(Palette.subdued))
                    .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .accessibilityIdentifier("add-search")
            }
            .padding(.horizontal, Space.m)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: Radius.s + 2).fill(Palette.elevatedHighlight))
            .padding(Space.gutter)
            ScrollView {
                LazyVStack(spacing: 0) {
                    if query.isEmpty { recommended }
                    if !query.isEmpty && searchFailed {
                        EntityLoadState(failed: true) { searchFailed = false; searchAttempt += 1 }
                    } else if !query.isEmpty && resultsFor != query {
                        SkeletonRows(count: 5)
                    } else if !query.isEmpty && results.isEmpty {
                        Text("No songs found for \"\(query)\"").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                            .frame(maxWidth: .infinity).padding(.top, Space.xxl)
                    }
                    ForEach(results) { s in row(s, id: "add-song") }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .foregroundStyle(Palette.text)
        .task(id: recsBatch) {
            recsLoading = true
            let got = (try? await app.core.playlistRecommendations(playlistId: id, n: 10, refresh: recsBatch)) ?? []
            guard !Task.isCancelled else { return }
            recs = got
            recsLoading = false
        }
        .task(id: "\(query)#\(searchAttempt)") {
            guard !query.isEmpty else { results = []; resultsFor = nil; searchFailed = false; return }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let q = query
            do {
                let got = try await app.core.search(query: q)
                guard q == query else { return }
                results = got; resultsFor = q; searchFailed = false
            } catch {
                guard q == query, !FriendlyError.isCancellation(error) else { return }
                results = []; searchFailed = true
            }
        }
    }

    @ViewBuilder private var recommended: some View {
        if recsLoading && recs.isEmpty {
            SkeletonRows(count: 3)
        } else if !recs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recommended songs").font(Typo.font(18, .bold)).accessibilityAddTraits(.isHeader)
                Text(recommendedNote(recs)).font(Typo.font(13)).foregroundStyle(Palette.subdued)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
            ForEach(recs, id: \.song.videoId) { r in row(r.song, id: "add-recommended") }
            Button { recsBatch += 1 } label: {
                Text("Refresh").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.l + 4).frame(height: 32)
                    .overlay(Capsule().stroke(Palette.muted, lineWidth: 1))
            }
            .buttonStyle(PressScale())
            .frame(maxWidth: .infinity)
            .padding(.vertical, Space.l)
            .disabled(recsLoading)
            .accessibilityIdentifier("add-recommended-refresh")
        }
    }

    private func row(_ s: SongItem, id ident: String) -> some View {
        HStack(spacing: Space.m) {
            ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
            VStack(alignment: .leading, spacing: 3) {
                Text(s.title).font(Typo.rowTitle).lineLimit(1)
                Text(s.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
            }
            Spacer(minLength: 0)
            let done = added.contains(s.videoId)
            Button { add(s) } label: {
                IconSwap(name: done ? "check-circle" : "plus-circle", fill: done, size: 26)
                    .foregroundStyle(done ? Palette.accent : Palette.text).frame(width: 44, height: 44)
            }
            .disabled(done)
            .accessibilityLabel(done ? "Added \(s.title)" : "Add \(s.title)")
            .accessibilityIdentifier(ident)
        }
        .padding(.horizontal, Space.gutter)
        .frame(height: Metrics.rowHeight)
    }

    private func add(_ s: SongItem) {
        added.insert(s.videoId)
        Haptics.impact(.light)
        Task {
            do {
                try await app.core.addToPlaylist(id: id, songs: [s])
                if !isLocalPlaylistId(id) { app.account.youtube.noteAdded(id, videoIds: [s.videoId]) }
                app.showToast("Added to \(name)")
            }
            catch { added.remove(s.videoId); app.fail(friendlyError(error, "Couldn't add to \(name)")) }
            await app.library.refresh()
        }
    }
}

/// Spotify asks first, then offers Undo in the toast.
@MainActor func confirmDeletePlaylist(_ app: AppModel, id: String, name: String) {
    // A playlist on the YouTube account is gone for good there (no Recover playlists), so no Undo.
    let local = isLocalPlaylistId(id)
    app.confirm = ConfirmRequest(title: "Delete \(name)?", message: local ? nil : "It will be deleted from your YouTube account too.", action: "Delete") {
        Task {
            do { try await app.core.deletePlaylist(id: id) } catch { app.fail(friendlyError(error, "Couldn't delete \(name)")); return }
            if !local { app.account.youtube.forget(id) }
            // Leave the deleted playlist's page wherever it is open.
            for t in [Tab.home, .search, .library] {
                if let i = app.router.paths[t]?.firstIndex(of: .playlist(id)) { app.router.paths[t] = Array(app.router.paths[t]![..<i]) }
            }
            await app.library.refresh()
            guard local else { return app.showToast("Deleted \(name)") }
            app.showToast("Deleted \(name)", action: "Undo") {
                Task {
                    do {
                        try await app.core.restorePlaylist(id: id)
                        app.showToast("Restored \(name)")
                    } catch {
                        app.showToast("Couldn't restore \(name). Try Recover playlists in Settings.")
                    }
                    await app.library.refresh()
                }
            }
        }
    }
}
