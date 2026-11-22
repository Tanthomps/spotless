// Stream ios-polish: the core side of the "Add to playlist" picker, real and mock.
import Foundation

extension RealCoreClient {
    func playlistsContaining(videoId: String) async throws -> [String] {
        try await call("lib_playlists_containing", ["videoId": videoId])
    }
    func removeFromPlaylist(id: String, videoIds: [String]) async throws {
        guard isLocalPlaylistId(id) else {
            return try await removeFromYouTubePlaylist(id, videoIds: videoIds, page: try await getPlaylist(id: id))
        }
        _ = try await call("lib_playlist_remove_videos", ["id": id, "videoIds": videoIds])
    }
    func song(videoId: String) async throws -> SongItem { try await call("song", ["videoId": videoId]) }
    func exportSong(videoId: String, to path: String) async throws {
        _ = try await call("song_export", ["videoId": videoId, "path": path])
    }
    func downloadedSongs(collectionId: String) async throws -> [SongItem] {
        try await call("downloads_collection_songs", ["id": collectionId])
    }
    /// Matching is done (phase `review`): write the lists, likes, saves and history, here or on
    /// the YouTube account (the desktop's ImportDialog `create`).
    func importCreate(names: [Int: String], local: Bool) async throws {
        let named = Dictionary(uniqueKeysWithValues: names.map { (String($0.key), $0.value) })
        _ = try await call("import_create", ["options": ["names": named, "local": local]])
    }
    /// First run: offer the import? The core's rule (`library::import_offer`), shared with the Mac.
    func importOffer() async throws -> Bool { try await call("import_offer") }
    func importOfferDone() async throws { _ = try await call("import_offer_done") }
}

extension MockCoreClient {
    func playlistsContaining(videoId: String) async throws -> [String] {
        withLock { playlists.filter { $0.items.contains { $0.videoId == videoId } }.map(\.meta.id) }
    }
    func removeFromPlaylist(id: String, videoIds: [String]) async throws {
        if let page = withLock({ ytPageLocked(id) }) { return try await removeFromYouTubePlaylist(id, videoIds: videoIds, page: page) }
        withLock {
            guard let i = playlists.firstIndex(where: { $0.meta.id == id }) else { return }
            playlists[i].items.removeAll { videoIds.contains($0.videoId) }
            playlists[i].meta.count = playlists[i].items.count
            playlists[i].meta.updatedAt = Date().timeIntervalSince1970
        }
        emit("library-changed", ["scope": "playlists"])
    }
    func exportSong(videoId: String, to path: String) async throws {
        try Data("demo".utf8).write(to: URL(fileURLWithPath: path))
    }
    func song(videoId: String) async throws -> SongItem {
        if let s = withLock({ pool.first { $0.videoId == videoId } }) { return s }
        throw CoreFailure(message: "not_found")
    }
    func downloadedSongs(collectionId: String) async throws -> [SongItem] {
        let done = try await downloadsSnapshot().done
        if let p = try? await getPlaylist(id: collectionId) { return p.items.filter { done.contains($0.videoId) } }
        return []
    }
}

/// Entity pages that still open offline: the network page, else the downloaded copy (Spotify
/// shows downloaded albums and playlists with no connection).
extension AppModel {
    func loadAlbum(_ id: String) async -> AlbumPage? {
        if let p = try? await core.getAlbum(id: id) { return p }
        guard let c = downloads.snapshot.collections.first(where: { $0.id == id }),
              let songs = try? await core.downloadedSongs(collectionId: id), !songs.isEmpty else { return nil }
        return AlbumPage(title: c.title, artist: c.subtitle ?? songs.first?.artists, artistId: songs.first?.artistId,
                         subtitle: "Album", thumbnail: c.thumbnail ?? songs.first?.thumbnail, items: songs, inLibrary: true)
    }

    func loadPlaylist(_ id: String) async -> PlaylistPage? {
        if let p = try? await core.getPlaylist(id: id) { return p }
        guard let c = downloads.snapshot.collections.first(where: { $0.id == id }),
              let songs = try? await core.downloadedSongs(collectionId: id), !songs.isEmpty else { return nil }
        return PlaylistPage(title: c.title, subtitle: c.subtitle, thumbnail: c.thumbnail ?? songs.first?.thumbnail,
                            items: songs, owned: false, collaborative: false)
    }
}
