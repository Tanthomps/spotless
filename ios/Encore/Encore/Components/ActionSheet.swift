// Bottom-sheet context menus (long-press or `…`): header with art + title + subtitle, then icon rows.
// Spotify uses its own sheet, not the system context-menu preview.
import SwiftUI

struct SheetRow: Identifiable {
    let id = UUID()
    var icon: String
    var fill = false
    var title: String
    var tint: Color = Palette.text
    /// Create-sheet style: icon in a 48pt circle well with a subtitle under the title.
    var subtitle: String? = nil
    /// Sort-sheet style: an accent check at the right of the current option.
    var checked: Bool? = nil
    var action: () -> Void
}

struct ActionSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let subject: SheetSubject
    /// Natural height of header + rows, for sheets that fit their content (Create, Sort).
    var onHeight: ((CGFloat) -> Void)? = nil
    @State private var headerH: CGFloat = 0
    @State private var rowsH: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                headerView.padding(.top, Space.xl)
                if hasHeader { Divider().overlay(Palette.border).padding(.top, Space.l) }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerH = $0; onHeight?(headerH + rowsH) }
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { r in
                        Button {
                            Haptics.selection()
                            dismiss()
                            r.action()
                        } label: {
                            HStack(spacing: Space.l) {
                                if let sub = r.subtitle {
                                    // Create sheet: 48 pt white-10 % circle, 24 pt light-grey line icon.
                                    Circle().fill(Color.white.opacity(0.1)).frame(width: 48, height: 48)
                                        .overlay(Icon(name: r.icon, size: 24).foregroundStyle(Color(hex: "#e0e0e0")))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.title).font(Typo.font(16, .bold)).foregroundStyle(Palette.text)
                                        Text(sub).font(Typo.font(14)).foregroundStyle(Palette.subdued).multilineTextAlignment(.leading)
                                    }
                                } else if let checked = r.checked {
                                    Text(r.title).font(Typo.sheetItem).foregroundStyle(checked ? Palette.accentText : Palette.text)
                                    Spacer()
                                    if checked { Icon(name: "check", size: 20).foregroundStyle(Palette.accent) }
                                } else {
                                    Icon(name: r.icon, fill: r.fill, size: 24).foregroundStyle(r.tint == Palette.text ? Palette.subdued : r.tint)
                                    Text(r.title).font(Typo.sheetItem).foregroundStyle(Palette.text)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Space.gutter)
                            .frame(minHeight: r.subtitle == nil ? 52 : 70)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(SheetRowStyle())
                    }
                }
                .padding(.vertical, Space.s)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsH = $0; onHeight?(headerH + rowsH) }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .foregroundStyle(Palette.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("action-sheet")
    }

    private var hasHeader: Bool {
        switch subject { case .track, .collection, .episode, .show: true; default: false }
    }

    @ViewBuilder private var headerView: some View {
        switch subject {
        case .track(let s, _):
            header(art: s.thumbnail, title: s.title, subtitle: s.artists)
        case .collection(let c):
            header(art: c.thumbnail, title: c.title, subtitle: c.subtitle ?? kindLabel(c.kind), circle: c.kind == .artist, liked: c.id == likedPlaylistId)
        case .create:
            EmptyView()
        case .sort:
            Text("Sort by").font(Typo.font(16, .bold)).padding(.horizontal, Space.gutter)
        case .episode(let e):
            header(art: e.thumbnail, title: e.title, subtitle: e.showTitle)
        case .show(let sh):
            header(art: sh.thumbnail, title: sh.title, subtitle: sh.author)
        default:
            EmptyView()
        }
    }

    /// ~72 pt header: 48 pt art (circle for artists), 12 gap, title 16/700, subtitle 14 subdued.
    private func header(art: String?, title: String, subtitle: String, circle: Bool = false, liked: Bool = false) -> some View {
        HStack(spacing: Space.m) {
            if liked { LikedCover(size: 48) } else {
                ArtImage(url: art, px: 144, radius: Radius.xs, circle: circle).frame(width: 48, height: 48)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.font(16, .bold)).lineLimit(1)
                Text(subtitle).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, Space.gutter)
    }

    private var rows: [SheetRow] {
        let router = app.router
        switch subject {
        case .track(let s, let ctx):
            // Spotify's order: playlist, Liked, queue, radio, album, artist, share, sleep timer, remove.
            let liked = app.library.isLiked(s.videoId)
            var r: [SheetRow] = [
                SheetRow(icon: "music-notes-plus", title: "Add to playlist") { reopen(.addToPlaylist([s])) },
                SheetRow(icon: liked ? "check-circle" : "plus-circle", fill: liked, title: liked ? "Remove from Liked Songs" : "Add to Liked Songs",
                         tint: liked ? Palette.accent : Palette.text) { app.toggleLike(s) },
                SheetRow(icon: "queue", title: "Add to queue") { app.queue([s], from: ctx?.title) },
                SheetRow(icon: "list-plus", title: "Play next") { app.playNext([s], from: ctx?.title) },
            ]
            let music = s.isEpisode != true
            // Episodes (search results, Now Playing): Download, like the episode sheet.
            if !music { r.insert(episodeDownloadRow(app, song: s), at: 2) }
            // The radio opens as a page; what is playing keeps playing (lane P1, the desktop's D1).
            if music {
                r.append(SheetRow(icon: "broadcast", title: "Go to song radio") { openRadio(kind: "song", id: s.videoId, name: s.title) })
            }
            if let a = s.albumId, ctx?.kind != .album {
                r.append(SheetRow(icon: "disc", title: "View album") { router.nowPlayingOpen = false; router.push(.album(a)) })
            }
            if let a = s.artistId ?? s.artistRuns?.first(where: { $0.id != nil })?.id {
                r.append(SheetRow(icon: "user", title: "View artist") { router.nowPlayingOpen = false; router.push(.artist(a)) })
            }
            if music {
                r.append(SheetRow(icon: "users-three", title: "Show credits") { CreditsPresenter.present(s, app: app) })
            }
            r.append(SheetRow(icon: "share-network", title: "Share") { ShareSheet.presentAfterSheet(.song(s), app: app) })
            if music {
                let taste = TasteExclusions.shared
                let excluded = taste.isExcluded(s.videoId, core: app.core)
                r.append(SheetRow(icon: "eye", fill: excluded,
                                  title: excluded ? "Include in your taste profile" : "Exclude from your taste profile") {
                    taste.toggle(app, id: s.videoId, kind: "song", title: s.title) { [s.videoId] }
                })
            }
            if music, let who = ArtistBlock.artist(of: s) {
                r.append(SheetRow(icon: "prohibit", title: "Don't play this artist") { ArtistBlock.block(app, id: who.id, name: who.name) })
            }
            if app.router.nowPlayingOpen {
                r.append(SheetRow(icon: "timer", title: app.settings.sleep.mode == nil ? "Sleep timer" : "Sleep timer is on",
                                  tint: app.settings.sleep.mode == nil ? Palette.text : Palette.accent) { reopen(.sleepTimer) })
            }
            // Tempo, pitch and reverb for the music playing now (session-wide, like the desktop's).
            if music, app.router.nowPlayingOpen || app.player.now?.videoId == s.videoId {
                let on = !app.effects.isOriginal
                r.append(SheetRow(icon: "sliders-horizontal", title: on ? "Speed & pitch is on" : "Speed & pitch",
                                  tint: on ? Palette.accent : Palette.text) { reopen(.effects) })
            }
            // Hide song (everywhere): playback steps over it from now on; Undo in the toast.
            if !(ctx?.id?.hasPrefix("LOCALPLAYLIST") ?? false), s.isEpisode != true {
                let hidden = app.library.isHidden(s.videoId)
                r.append(SheetRow(icon: "prohibit", title: hidden ? "Unhide song" : "Hide song") {
                    Task {
                        do {
                            try await app.core.setHidden(s, hidden: !hidden)
                            await app.library.refresh()
                            await app.player.refresh()
                            if hidden { app.showToast("Song unhidden"); return }
                            // Hiding what is playing moves on, as Spotify does.
                            if app.player.now?.videoId == s.videoId { app.player.skipNext() }
                            app.showToast("Song hidden", action: "Undo") {
                                Task {
                                    do { try await app.core.setHidden(s, hidden: false) } catch { app.fail(friendlyError(error, "Couldn't unhide it")) }
                                    await app.library.refresh(); await app.player.refresh()
                                }
                            }
                        } catch { app.fail(friendlyError(error, "Couldn't hide it")) }
                    }
                })
            }
            // Own playlists: take the song out of this playlist (the old "Hide song" row only toasted).
            if let pid = ctx?.id, app.isOwnPlaylist(pid), ctx?.kind == .playlist {
                r.append(SheetRow(icon: "minus-circle", title: "Remove from this playlist") {
                    // Undo puts it back where it was (the desktop's restoreorder).
                    PlaylistUndo.remove(app, song: s, playlistId: pid, playlistName: ctx?.title)
                })
            }
            return r
        case .collection(let c) where c.kind == .audiobook:
            // stream: audiobooks — saved in the books store; the book page has the rest.
            let saved = app.books.isSaved(c.id)
            return [
                SheetRow(icon: saved ? "check-circle" : "plus-circle", fill: saved, title: saved ? "Remove from Your Library" : "Add to Your Library",
                         tint: saved ? Palette.accent : Palette.text) {
                    let book = app.books.saved.first { $0.id == c.id }
                        ?? Audiobook(id: c.id, title: c.title, author: c.subtitle ?? "", thumbnail: c.thumbnail, genres: [], saved: false)
                    let on = app.books.toggleSaved(book)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                },
                pinRow(c),
                SheetRow(icon: "share-network", title: "Share") { ShareSheet.presentAfterSheet(.item(c), app: app) },
            ]
        case .collection(let c):
            let own = app.isOwnPlaylist(c.id)
            let saved = app.inLibrary(c) || own || c.id == likedPlaylistId
            var r: [SheetRow] = []
            if c.id != likedPlaylistId && !own {
                r.append(SheetRow(icon: saved ? "check-circle" : "plus-circle", fill: saved,
                                  title: c.kind == .artist ? (saved ? "Unfollow" : "Follow") : (saved ? "Remove from Your Library" : "Add to Your Library"),
                                  tint: saved ? Palette.accent : Palette.text) {
                    let on = app.toggleInLibrary(c)
                    app.showToast(on ? "Added to Your Library" : "Removed from Your Library")
                })
            }
            r += [
                downloadRow(c),
            ]
            // Albums and playlists only: an artist has no fixed track list to queue.
            if c.kind == .album || c.kind == .playlist {
                r.append(SheetRow(icon: "queue", title: "Add to queue") {
                    Task {
                        do {
                            let items = c.kind == .album ? try await app.core.getAlbum(id: c.id).items : try await app.core.getPlaylist(id: c.id).items
                            if items.isEmpty { app.showToast("Nothing to add from \(c.title)") } else { app.queue(items, from: c.title) }
                        } catch {
                            app.fail(friendlyError(error, "Couldn't add to queue"))
                        }
                    }
                })
            }
            r += [
                pinRow(c),
                SheetRow(icon: "share-network", title: "Share") { ShareSheet.presentAfterSheet(.item(c), app: app) },
            ]
            // Radio pages (lane P1). Playlists on this phone, Liked Songs and Made for you have no
            // YouTube radio, as on the desktop.
            let ytPlaylist = c.kind == .playlist && c.id != likedPlaylistId && !c.id.hasPrefix("LOCALPLAYLIST") && !isMadeForYouId(c.id)
            if c.kind == .artist || c.kind == .album || ytPlaylist {
                let label = c.kind == .artist ? "Go to artist radio" : c.kind == .album ? "Go to album radio" : "Go to playlist radio"
                r.append(SheetRow(icon: "broadcast", title: label) { openRadio(kind: c.kind.rawValue, id: c.id, name: c.title) })
            }
            if c.kind == .playlist && c.id != likedPlaylistId {
                let taste = TasteExclusions.shared
                let excluded = taste.isExcluded(c.id, core: app.core)
                r.append(SheetRow(icon: "eye", fill: excluded,
                                  title: excluded ? "Include in your taste profile" : "Exclude from your taste profile") {
                    let core = app.core
                    taste.toggle(app, id: c.id, kind: "playlist", title: c.title) {
                        ((try? await core.getPlaylist(id: c.id))?.items ?? []).map(\.videoId)
                    }
                })
            }
            if c.kind == .artist {
                r.append(SheetRow(icon: "prohibit", title: "Don't play this artist") { ArtistBlock.block(app, id: c.id, name: c.title) })
            }
            if own {
                r.insert(contentsOf: [
                    SheetRow(icon: "music-notes-plus", title: "Add to this playlist") { reopen(.addSongs(c.id, c.title)) },
                    SheetRow(icon: "pencil-simple", title: "Edit playlist") { reopen(.editPlaylist(c.id)) },
                ], at: 0)
                r.append(SheetRow(icon: "x-circle", title: "Delete playlist") {
                    Task { try? await Task.sleep(nanoseconds: 450_000_000); confirmDeletePlaylist(app, id: c.id, name: c.title) }
                })
            }
            if c.id.hasPrefix("LOCALPLAYLIST"), let folders = app.library.snapshot.folders, !folders.isEmpty {
                let inFolder = folders.first { $0.items.contains(c.id) }
                for f in folders.prefix(6) where f.id != inFolder?.id {
                    r.append(SheetRow(icon: "folder", title: "Move to \(f.name)") {
                        Task {
                            do {
                                try await app.core.moveToFolder(itemId: c.id, folderId: f.id)
                                app.showToast("Moved to \(f.name)")
                            } catch { app.fail(friendlyError(error, "Couldn't move it to \(f.name)")) }
                            await app.library.refresh()
                        }
                    })
                }
                if let inFolder {
                    r.append(SheetRow(icon: "folder", title: "Remove from \(inFolder.name)") {
                        Task {
                            do {
                                try await app.core.moveToFolder(itemId: c.id, folderId: nil)
                                app.showToast("Removed from \(inFolder.name)")
                            } catch { app.fail(friendlyError(error, "Couldn't take it out of \(inFolder.name)")) }
                            await app.library.refresh()
                        }
                    })
                }
            }
            return r
        case .create:
            return [
                SheetRow(icon: "music-notes-plus", title: "Playlist", subtitle: "Collect songs and episodes in one list") { reopen(.newPlaylist) },
                SheetRow(icon: "folder", title: "Folder", subtitle: "Keep related playlists together") { reopen(.newFolder) },
            ]
        case .episode(let e):
            return episodeSheetRows(app, e)
        case .show(let sh):
            return showSheetRows(app, sh)
        case .sleepTimer, .speed, .chapters, .effects, .aboutRecommendations, .newFolder, .newPlaylist, .addToPlaylist, .editPlaylist, .addSongs:
            return []
        case .sort:
            // Custom order only applies to playlists (Spotify).
            return LibrarySort.allCases.filter { $0 != .custom || app.libraryFilter == "Playlists" }.map { s in
                SheetRow(icon: "", title: s.rawValue, checked: app.librarySort == s) {
                    Haptics.selection()
                    app.librarySort = s
                }
            }
        }
    }
}

/// An action sheet whose detent is its own content height (Create, Sort): no dead space under the rows.
struct FittedActionSheet: View {
    let subject: SheetSubject
    @State private var height: CGFloat = 200
    private var bottomInset: CGFloat {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        return w?.safeAreaInsets.bottom ?? 0
    }
    var body: some View {
        // iOS 27's floating sheet adds the home-indicator inset below the detent height; take it back.
        ActionSheet(subject: subject) { h in if h > 0 { height = h + Space.l - bottomInset } }
            .presentationDetents([.height(height)])
    }
}

/// Picking a row dismisses this sheet; open the next one after the dismissal settles.
@MainActor func reopenSheet(_ app: AppModel, _ s: SheetSubject) {
    Task { try? await Task.sleep(nanoseconds: 450_000_000); app.sheet = s }
}

extension ActionSheet {
    func reopen(_ s: SheetSubject) { reopenSheet(app, s) }

    /// "Go to … radio": the radio page over the current tab (Now Playing closes, playback goes on).
    func openRadio(kind: String, id: String, name: String?) {
        app.router.nowPlayingOpen = false
        app.router.queueOpen = false
        app.router.push(.radio(kind, id, name))
    }

    /// Download / Remove download (Spotify asks before removing).
    func downloadRow(_ c: BrowseItem) -> SheetRow {
        let on = app.downloads.isCollectionDownloaded(c.id)
        return SheetRow(icon: on ? "arrow-circle-down" : "arrow-circle-down", fill: on, title: on ? "Remove download" : "Download",
                        tint: on ? Palette.accent : Palette.text) {
            toggleDownload(app, c)
        }
    }

    func pinRow(_ c: BrowseItem) -> SheetRow {
        let pinned = app.library.snapshot.pinnedIds.contains(c.id)
        return SheetRow(icon: "push-pin", fill: pinned, title: pinned ? "Unpin \(kindLabel(c.kind).lowercased())" : "Pin \(kindLabel(c.kind).lowercased())",
                        tint: pinned ? Palette.accent : Palette.text) {
            app.library.setPinned(c, !pinned)
            app.showToast(pinned ? "Unpinned" : "Pinned")
        }
    }
}

/// The download toggle's action, shared by entity pages and sheets.
@MainActor func toggleDownload(_ app: AppModel, _ c: BrowseItem) {
    if app.downloads.isCollectionDownloaded(c.id) {
        app.confirm = ConfirmRequest(title: "Remove from Downloads?", message: "You won't be able to play this offline.", action: "Remove") {
            app.downloads.remove(c.id)
        }
    } else {
        let kind = c.id == likedPlaylistId ? "liked" : c.kind == .album ? "album" : "playlist"
        // Spotify: downloading an album or someone else's playlist adds it to Your Library, which
        // is where Downloaded lists it (and the only way back to it offline).
        if c.id != likedPlaylistId, !app.isOwnPlaylist(c.id), !app.inLibrary(c), c.kind == .album || c.kind == .playlist {
            app.toggleInLibrary(c)
        }
        app.downloads.add(DownloadCollection(id: c.id, kind: kind, title: c.title, subtitle: c.subtitle, thumbnail: c.thumbnail))
        Haptics.impact(.light)
        DownloadKeeper.shared.userStartedDownload(title: c.title)
    }
}

private struct SheetRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Palette.tinted : .clear)
    }
}
