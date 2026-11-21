// The app's only door to the core. Mirrors the mobile subset of the desktop `api.ts` (commands in,
// events out). Today `MockCoreClient` answers it from the desktop devmock fixtures; stream S2 adds a
// UniFFI-backed `EncoreCoreClient` (an `EncoreCore` object with async methods plus an
// `EventListener` callback interface `on_event(name, json)`), and nothing above this file changes.
import Foundation

/// The playing context a track list was started from (the "PLAYING FROM …" header, queue "Next from").
struct PlayContext: Codable, Hashable {
    enum Kind: String, Codable { case playlist, album, artist, liked, search, radio, song, dailyMix = "daily_mix", audiobook }
    var kind: Kind
    var id: String?
    var title: String
}

/// Same shape as the UniFFI callback interface: event name plus the JSON payload the desktop's
/// Tauri event carries (`queue-changed`, `now-playing`, `position`, `playback-state`, ...).
protocol CoreEventListener: AnyObject, Sendable {
    func onEvent(name: String, json: Data)
}

protocol CoreClient: AnyObject, Sendable {
    // browse / search
    func search(query: String) async throws -> [SongItem]
    func searchAll(query: String, recordHistory: Bool) async throws -> SearchResults
    func searchSuggestions(query: String) async throws -> SearchSuggestions
    // stream: search2
    func searchOverview(query: String) async throws -> SearchOverview
    func searchPage(query: String, filter: String, continuation: String?) async throws -> SearchPage
    func searchLyrics(query: String) async throws -> [LyricMatch]
    func searchBlendLyrics(query: String, songs: [SongItem], lyric: [LyricMatch], interacted: Bool, topTitle: String?) async throws -> LyricBlend
    func getHome(params: String?) async throws -> HomePage
    func smartHome() async throws -> [Shelf]
    func getMoods() async throws -> [MoodSection]
    func getMoodArt(params: [String]) async throws -> [String: String]
    func getAlbum(id: String) async throws -> AlbumPage
    func getArtist(id: String) async throws -> ArtistPage
    func getPlaylist(id: String) async throws -> PlaylistPage
    func getLyrics(videoId: String, title: String, artists: String, duration: Double?) async throws -> Lyrics?

    // library
    func librarySnapshot() async throws -> LibrarySnapshot
    func recentContexts(limit: Int) async throws -> [RecentContext]
    func setLiked(_ song: SongItem, liked: Bool) async throws
    func setSaved(_ item: BrowseItem, saved: Bool) async throws
    func createPlaylist(name: String) async throws -> LibPlaylist

    // playback
    func getQueue() async throws -> QueueState
    func getPlayback() async throws -> PlaybackSnapshot
    /// `startSecs` opens the start row that far in (a chapter tapped before its episode plays), in
    /// the same call, so it holds while the stream resolves. Core `play_playlist`.
    func playPlaylist(items: [SongItem], start: Int, context: PlayContext, shuffle: Bool, startSecs: Double?) async throws
    /// A single pick (a search result, a Home card, a song link): this song only, then Autoplay.
    /// `from` labels "Playing from" (the search query). Core `play`.
    func playSingle(_ song: SongItem, from: String?) async throws
    /// stream: firstaudio. A finger came down on this song's row: resolve its stream now, so the
    /// tap (if it is one) starts from the cache. Fire and forget; the core rations it. Core `hint_play`.
    func hintPlay(_ song: SongItem)
    func playIndex(_ index: Int) async throws
    func startRadio(song: SongItem) async throws
    func nextTrack() async throws
    func prevTrack() async throws
    func togglePause() async throws
    func seek(position: Double) async throws
    func toggleShuffle() async throws
    func setRepeat(_ mode: RepeatMode) async throws
    func addToQueue(_ items: [SongItem], from: String?) async throws
    func playNext(_ items: [SongItem], from: String?) async throws
    func removeFromQueue(index: Int) async throws
    func moveInQueue(from: Int, to: Int) async throws

    // playback extras (episodes: speed + 15 s skips; api.ts setPlaybackParams / seek)
    func setSpeed(_ rate: Double) async throws
    /// Music: tempo, pitch and reverb at once (`set_playback_params`).
    func setPlaybackParams(_ effects: PlaybackEffects) async throws
    func seekRelative(_ seconds: Double) async throws

    // podcasts (api.ts podcast*)
    func podcastSearch(query: String) async throws -> PodcastSearchResults
    func podcastShow(id: String, sort: EpisodeSort) async throws -> PodcastShowPage
    func podcastEpisode(id: String) async throws -> PodcastEpisode
    func podcastChapters(id: String, durationSecs: Double?) async throws -> PodcastChapters // stream: chapters
    func podcastEpisodeVideo(id: String) async throws -> EpisodeVideo? // stream: video-pods
    func podcastFollow(_ show: PodcastShow, follow: Bool) async throws
    func podcastFollows() async throws -> [PodcastShow]
    func podcastSavedEpisodes() async throws -> [PodcastEpisode]
    func podcastNewEpisodes(limit: Int) async throws -> [PodcastEpisode]
    func podcastContinueListening(limit: Int) async throws -> [PodcastEpisode]
    func podcastSaveEpisode(_ episode: PodcastEpisode, saved: Bool) async throws
    func podcastMarkPlayed(id: String, played: Bool) async throws -> EpisodeProgress

    // audio (api.ts audio stream)
    func audioSettings() async throws -> AudioSettings
    func eqInfo() async throws -> EqInfo
    func setEq(enabled: Bool, gains: [Double], commit: Bool) async throws -> EqState
    func setEqPreset(_ name: String) async throws -> EqState
    func setCrossfade(seconds: Int) async throws -> Int
    func setNormalize(_ on: Bool) async throws
    func setVolumeLevel(_ level: VolumeLevel) async throws
    func setSleepTimer(minutes: Int?, endOfTrack: Bool) async throws -> SleepState
    func cancelSleepTimer() async throws -> SleepState

    // smart (smart.md, smart2.md)
    func smartSettings() async throws -> SmartSettings
    func smartSetSetting(key: String, value: String) async throws
    func madeForYou() async throws -> [MfyCard]
    /// A Home "Your Mix" tile's songs (`smart_mix`; id `dailymix:<artist keys>`).
    func smartMix(id: String, size: Int?) async throws -> [SongItem]
    func whatsNew() async throws -> WhatsNew
    func whatsNewMarkSeen() async throws
    func smartShuffleState() async throws -> SmartShuffleState
    func smartShuffleSet(_ on: Bool) async throws -> SmartShuffleState

    // downloads (downloads.md)
    func downloadsSnapshot() async throws -> DownloadsSnapshot
    func downloadsAdd(_ collection: DownloadCollection, songs: [SongItem]?) async throws
    func downloadsRemove(id: String) async throws
    func downloadsRemoveAll() async throws
    func downloadsSetSettings(_ patch: DownloadSettingsPatch) async throws -> DownloadsSnapshot

    // library extras (lib_pin / lib_unpin / lib_folder_create / lib_set_private_session)
    func setPinned(id: String, kind: String, pinned: Bool) async throws
    func createFolder(name: String) async throws -> Folder
    func setPrivateSession(_ on: Bool) async throws

    // settings key/value (get_settings / set_setting)
    func getSettings() async throws -> [String: String]
    func setSetting(key: String, value: String) async throws

    // Spotify import (import_read / import_read_file / import_start / import_status)
    func importRead(link: String) async throws -> ImportPreview
    func importReadFile(url: URL) async throws -> ImportPreview
    func importStart(lists: [Int]) async throws -> ImportSnapshot
    func importStatus() async throws -> ImportSnapshot?

    // The last actions that were UI-local (stream ios-wire): Smart Shuffle −/+, Storage, folders,
    // more show episodes, add to playlist, artist/album radio.
    func smartShuffleRemove(videoId: String) async throws -> SmartShuffleState   // smart_shuffle_remove
    func smartShuffleKeep(videoId: String) async throws -> SmartShuffleState     // smart_shuffle_keep
    func cacheSize() async throws -> Double                                      // cache_size (bytes)
    func clearCaches() async throws                                              // clear_caches
    func moveToFolder(itemId: String, folderId: String?) async throws            // lib_folder_set_item
    func podcastShowMore(id: String, continuation: String, sort: EpisodeSort) async throws -> PodcastEpisodePage // podcast_show_more
    func addToPlaylist(id: String, songs: [SongItem]) async throws               // lib_playlist_add
    func startRadio(kind: String, id: String, name: String?) async throws        // start_radio (artist | album | playlist)

    // Own-playlist editing (Spotify: Edit playlist, Delete with Undo) and the queue's Clear queue
    // (stream ios-e2e).
    func whatsNewRefreshed() async throws -> WhatsNew                              // whats_new {refresh: true}
    func setHidden(_ song: SongItem, hidden: Bool) async throws                    // lib_hide_song / lib_unhide_song
    func clearQueued() async throws                                                // clear_queued
    func updatePlaylist(id: String, name: String?, description: String?) async throws // lib_playlist_update
    func deletePlaylist(id: String) async throws                                   // lib_playlist_delete
    func restorePlaylist(id: String) async throws                                  // lib_playlist_restore
    func playlistEntries(id: String) async throws -> [PlaylistEntry]               // lib_playlist_entries
    func removeFromPlaylist(id: String, rowIds: [Int64]) async throws              // lib_playlist_remove
    func setPlaylistOrder(id: String, rowIds: [Int64]) async throws                // lib_playlist_set_order
    // Stream ios-polish: the "Add to playlist" picker (checkmarks, uncheck removes).
    func playlistsContaining(videoId: String) async throws -> [String]           // lib_playlists_containing
    func removeFromPlaylist(id: String, videoIds: [String]) async throws         // lib_playlist_remove_videos
    func song(videoId: String) async throws -> SongItem                          // song (shared links)
    func downloadedSongs(collectionId: String) async throws -> [SongItem]        // downloads_collection_songs
    /// `names`: a new name per list index; `local`: on this phone rather than the YouTube account.
    func importCreate(names: [Int: String], local: Bool) async throws            // import_create
    func importOffer() async throws -> Bool                                      // import_offer
    func importOfferDone() async throws                                          // import_offer_done
    // Stream ios-import-review: the review step.
    func importRows(tier: String) async throws -> [ImportRow]                    // import_rows (matched | check | missing)
    func importPick(key: String, song: SongItem?) async throws -> ImportSnapshot // import_pick (nil leaves it out)

    // Stream magic-ib: entity pages (EntityModels.swift).
    /// "Recommended" under your own playlist; `refresh` counts presses of Refresh (next seeds).
    func playlistRecommendations(playlistId: String, n: Int, refresh: Int) async throws -> [Recommendation] // playlist_recommendations
    /// A playlist in YouTube's stored order (`sort`: default | newest | oldest | title | artist | album).
    func getPlaylist(id: String, sort: String?, desc: Bool) async throws -> PlaylistPage   // get_playlist {sort, desc}
    /// Write the order back to YouTube: playlists you own there only (the core refuses the rest).
    func setPlaylistSort(playlistId: String, sort: String) async throws                    // set_playlist_sort
    /// Albums + Singles & EPs, each expanded through its "more" page (get_artist + get_browse_grid).
    func artistDiscography(id: String) async throws -> Discography
    /// videoId → may play (hidden, blocked artist, explicit with the filter on).
    func playableFlags(_ items: [SongItem]) async throws -> [String: Bool]                 // playable_flags
    /// Home's local shelves only (shortcuts, recents, jump back in, mixes): no network, a few ms.
    /// The instant revalidate after a `home-changed` `played` (gap #2, lane I-C).
    func smartHomeLocal() async throws -> [Shelf]                                            // smart_home_local
    /// stream: home-tiles-pods — Home's Podcasts chip: your shows plus suggestions (`smart::podhome`).
    func podcastHome() async throws -> [Shelf]                                               // podcast_home
    /// A podcast category tile's page: Apple's top shows in that genre.
    func podcastCategory(genre: String) async throws -> [ShelfItem]                          // podcast_category {genre}

    // stream: audiobooks — LibriVox books (crates/core/src/audiobooks).
    func audiobookSearch(query: String) async throws -> [Audiobook]                          // audiobook_search {query}
    func audiobookHome() async throws -> [Shelf]                                             // audiobook_home
    func audiobookGenre(genre: String) async throws -> [Audiobook]                           // audiobook_genre {genre}
    func audiobookPage(id: String) async throws -> AudiobookPage                             // audiobook_page {id}
    func audiobookForChapter(id: String) async throws -> AudiobookPage?                      // audiobook_for_chapter {id}
    func audiobookSave(_ book: Audiobook, saved: Bool) async throws                          // audiobook_save {book, saved}
    func audiobookSaved() async throws -> [Audiobook]                                        // audiobook_saved

    // Lane D1's commands (UI follows separately).
    /// A radio's tracks without playing (`kind`: song | artist | album | playlist).
    func radioTracks(kind: String, id: String, name: String?) async throws -> RadioPage    // radio_tracks
    /// One song from `start` seconds (a song link's `t=`), then Autoplay.
    func playSingleAt(_ song: SongItem, from: String?, start: Double?) async throws        // play_single_at
    func songCredits(_ song: SongItem) async throws -> SongCredits                         // song_credits
    /// Exclude a song or playlist (`kind`: song | playlist) from the taste profile, or include it again.
    func tasteSetExcluded(id: String, kind: String, title: String?, videoIds: [String], excluded: Bool) async throws // taste_set_excluded
    func tasteExcluded() async throws -> [String]                                          // taste_excluded

    // Stream magic-ib, I-B2 (SYNC-GAPS §1): the bridge for lanes P1–P3 (SyncModels.swift).
    /// Clear-queue Undo: put the cleared rows back; answers how many.
    func restoreQueued(_ items: [SongItem]) async throws -> Int                            // restore_queued
    func smartTagsLiked() async throws -> LikedChips                                       // smart_tags_liked
    func enhanceState(playlistId: String) async throws -> EnhanceState                     // enhance_state
    func enhanceSet(playlistId: String, on: Bool, len: Int) async throws -> EnhanceState   // enhance_set
    func enhanceRemove(playlistId: String, videoId: String) async throws -> EnhanceState   // enhance_remove
    func enhanceKeep(playlistId: String, videoId: String) async throws -> EnhanceState     // enhance_keep
    func deletedPlaylists() async throws -> [DeletedPlaylist]                              // lib_deleted_playlists
    func recentTracks(limit: Int?) async throws -> [RecentTrack]                           // lib_recent_tracks
    func recentPlayContexts(limit: Int?) async throws -> [RecentPlayContext]               // recent_play_contexts
    /// `since`: unix seconds (0 = all time).
    func listeningStats(since: Int64) async throws -> ListeningStats                       // listening_stats
    func topArtists(limit: Int) async throws -> [TopArtist]                                // top_artists
    func clearListeningHistory() async throws                                              // clear_listening_history
    func blockedArtists() async throws -> [BlockedArtist]                                  // get_blocked_artists
    func blockArtist(id: String?, name: String) async throws -> [BlockedArtist]            // block_artist
    func unblockArtist(key: String) async throws -> [BlockedArtist]                        // unblock_artist
    func renameFolder(id: String, name: String) async throws                               // lib_folder_rename
    func deleteFolder(id: String) async throws -> FolderSnapshot                           // lib_folder_delete
    func restoreFolder(_ snapshot: FolderSnapshot) async throws -> Folder                  // lib_folder_restore
    /// `path`: a local image file (nil drops the custom cover).
    func setPlaylistCover(playlistId: String, path: String?) async throws -> PlaylistCoverResult // set_playlist_cover
    /// A YouTube playlist's next page; `token` is the page's continuation.
    func playlistMore(token: String) async throws -> PlaylistMore                          // get_playlist_more
    /// The first page's continuation token (the app's `PlaylistPage` model doesn't carry it).
    func playlistContinuation(id: String) async throws -> String?                          // get_playlist (continuation)

    // Stream ios-sync2: Search › Browse pages and Appears on (CoreClient+Browse.swift).
    func getCharts(country: String?) async throws -> ChartsPage                            // get_charts
    func getNewReleases() async throws -> NewReleasesPage                                  // get_new_releases
    /// A genre/mood page (`browseId` = `moodsCategoryId`, `params` from the tile).
    func getBrowseSections(browseId: String, params: String?) async throws -> SectionsPage // get_browse_sections
    /// Releases by others the artist is on (`songsId`: the artist page's `topSongsId`).
    func getArtistAppearsOn(id: String, songsId: String) async throws -> [BrowseItem]      // get_artist_appears_on

    // Parity port (CoreClient+Ported.swift): Settings › Podcasts, the lyrics ⋯ menu, Spotify links, Export library.
    func podcastSettings() async throws -> PodcastSettings                                 // podcast_settings
    /// Partial: nil leaves a field as it is.
    func podcastSetSettings(sponsorblock: Bool?, categories: [String]?) async throws -> PodcastSettings // podcast_set_settings
    func podcastYouTubeMatch() async throws -> Bool                                        // podcast_youtube_match
    func podcastSetYouTubeMatch(_ on: Bool) async throws -> Bool                           // podcast_set_youtube_match
    func podcastOpmlImport(xml: String) async throws -> OpmlImportReport                   // podcast_opml_import
    func podcastOpmlExport() async throws -> String                                        // podcast_opml_export
    func lyricsProviders() async throws -> [LyricsProvider]                                // lyrics_providers
    /// `source` nil: back to automatic.
    func chooseLyricsSource(videoId: String, title: String, artists: String, duration: Double?, source: String?) async throws -> Lyrics? // choose_lyrics_source
    /// Answers the offset kept (the core clamps it).
    func setLyricsOffset(videoId: String, offsetMs: Int) async throws -> Int              // set_lyrics_offset
    func importResolve(link: String) async throws -> SpotifyResolved                       // import_resolve
    /// The library zip (CSV, M3U, XSPF) written to `path`.
    func libExport(path: String) async throws -> LibraryExportReport                       // lib_export

    // Device sync (docs/SYNC.md; Core/DeviceSync.swift). Errors are the core's codes (`wrong_code:2`, `not_pairing`, `no_host`).
    func syncStatus() async throws -> SyncStatus                                           // sync_status
    func syncStartPairing() async throws -> SyncPairingStart                               // sync_start_pairing
    func syncCancelPairing() async throws -> SyncStatus                                    // sync_cancel_pairing
    /// `qr`: a `spotless://pair` link; `host`/`port`: a device showing a code, found with Bonjour.
    func syncJoin(code: String?, qr: String?, host: String?, port: Int?) async throws -> SyncStatus // sync_join
    func syncUnpair() async throws -> SyncStatus                                           // sync_unpair
    func syncNow() async throws -> SyncStatus                                              // sync_now
    func syncSetActive(_ active: Bool) async throws -> SyncStatus                          // sync_set_active
    /// Other linked devices playing something ("Playing on <device>").
    func presenceList() async throws -> [RemoteDevice]                                     // presence_list
    /// Control another linked device: play, pause, next, prev.
    func presenceSend(dev: String, cmd: String) async throws                               // presence_send

    // events
    func setListener(_ listener: CoreEventListener?)
}

struct QueueIndex: Codable {
    var currentIndex: Int
    var shuffle: Bool?
    var `repeat`: RepeatMode?
    var sourceName: String?
    var sourceId: String?
    var current: SongItem?
}

struct QueueAppended: Codable {
    var items: [SongItem]
    var len: Int
    var currentIndex: Int
}

/// Decoded form of the event stream, for the stores.
enum CoreEvent {
    case queueChanged(QueueState)
    /// The pointer moved, the rows didn't (`queue-index`; api.ts `QueueIndex`).
    case queueIndex(QueueIndex)
    /// Autoplay appended rows (`queue-appended`).
    case queueAppended(QueueAppended)
    case playbackError(String)
    case nowPlaying(NowPlaying)
    case position(Double)
    case duration(Double)
    case playbackState(paused: Bool)
    case rating(videoId: String, rating: Rating)
    case libraryChanged(scope: String)
    case podcastProgress(id: String, progress: EpisodeProgress)
    case downloadsChanged
    case downloadsProgress([DownloadProgress])
    case downloadsNetwork(DownloadNetwork)
    case sleepTimer(SleepState)
    case smartShuffle(SmartShuffleState)
    case whatsNewChanged(Int)
    case madeForYouChanged
    /// YouTube's shelves that missed Home's time budget have landed: reload Home (`home-changed`).
    case homeChanged
    case importProgress(ImportSnapshot)
    case playbackParams(PlaybackEffects)
    /// Device sync's status changed (`sync-changed`); remote data also fires library/home events.
    case syncChanged(SyncStatus)
    case presenceChanged([RemoteDevice])
    case unknown(String)

    static func decode(name: String, json: Data) -> CoreEvent {
        let d = JSONDecoder()
        struct Pos: Decodable { var position: Double }
        struct Dur: Decodable { var duration: Double }
        struct Rate: Decodable { var videoId: String; var rating: Rating }
        struct Scope: Decodable { var scope: String }
        switch name {
        case "queue-changed": if let q = try? d.decode(QueueState.self, from: json) { return .queueChanged(q) }
        case "queue-index": if let q = try? d.decode(QueueIndex.self, from: json) { return .queueIndex(q) }
        case "queue-appended": if let q = try? d.decode(QueueAppended.self, from: json) { return .queueAppended(q) }
        case "playback-error":
            struct M: Decodable { var message: String }
            if let m = try? d.decode(M.self, from: json) { return .playbackError(m.message) }
        case "now-playing": if let n = try? d.decode(NowPlaying.self, from: json) { return .nowPlaying(n) }
        case "position": if let p = try? d.decode(Pos.self, from: json) { return .position(p.position) }
        case "duration": if let p = try? d.decode(Dur.self, from: json) { return .duration(p.duration) }
        case "playback-state": if let s = try? d.decode(String.self, from: json) { return .playbackState(paused: s == "paused") }
        case "rating": if let r = try? d.decode(Rate.self, from: json) { return .rating(videoId: r.videoId, rating: r.rating) }
        case "library-changed": if let s = try? d.decode(Scope.self, from: json) { return .libraryChanged(scope: s.scope) }
        case "podcasts:progress":
            struct P: Decodable { var id: String; var progress: EpisodeProgress }
            if let p = try? d.decode(P.self, from: json) { return .podcastProgress(id: p.id, progress: p.progress) }
        case "downloads:changed": return .downloadsChanged
        case "downloads:progress": if let p = try? d.decode([DownloadProgress].self, from: json) { return .downloadsProgress(p) }
        case "downloads:network": if let n = try? d.decode(DownloadNetwork.self, from: json) { return .downloadsNetwork(n) }
        case "sleep-timer": if let s = try? d.decode(SleepState.self, from: json) { return .sleepTimer(s) }
        case "smart-shuffle-changed": if let s = try? d.decode(SmartShuffleState.self, from: json) { return .smartShuffle(s) }
        case "whats-new-changed":
            struct N: Decodable { var newCount: Int }
            if let n = try? d.decode(N.self, from: json) { return .whatsNewChanged(n.newCount) }
        case "made-for-you-changed": return .madeForYouChanged
        case "home-changed": return .homeChanged
        case "import-progress": if let s = try? d.decode(ImportSnapshot.self, from: json) { return .importProgress(s) }
        case "sync-changed":
            struct S: Decodable { var status: SyncStatus }
            if let s = try? d.decode(S.self, from: json) { return .syncChanged(s.status) }
        case "presence-changed": if let p = try? d.decode([RemoteDevice].self, from: json) { return .presenceChanged(p) }
        case "playback-params":
            if let e = try? d.decode(PlaybackEffects.self, from: json) { return .playbackParams(e) }
        default: break
        }
        return .unknown(name)
    }
}

// stream: firstaudio — nothing to warm in the mock.
extension CoreClient {
    func hintPlay(_ song: SongItem) {}
}

// stream: pod-fixes — most plays start at the top.
extension CoreClient {
    func playPlaylist(items: [SongItem], start: Int, context: PlayContext, shuffle: Bool) async throws {
        try await playPlaylist(items: items, start: start, context: context, shuffle: shuffle, startSecs: nil)
    }
}

// stream: search2 — the mock composes the All view from its fixtures; the real core answers it.
extension CoreClient {
    func searchLyrics(query: String) async throws -> [LyricMatch] { [] }
    func searchBlendLyrics(query: String, songs: [SongItem], lyric: [LyricMatch], interacted: Bool, topTitle: String?) async throws -> LyricBlend {
        LyricBlend(songs: songs, leadTop: false, added: [])
    }

    func searchOverview(query: String) async throws -> SearchOverview {
        let r = try await searchAll(query: query, recordHistory: false)
        let p = (try? await podcastSearch(query: query)) ?? PodcastSearchResults(shows: [], episodes: [])
        // Songs stay cards here (`songs: []` makes the Top list use `results.songs`): a card → song → card round trip
        // would rebuild the artist line from its runs.
        return SearchOverview(query: query, correction: nil, results: r, songs: [], songsContinuation: nil,
                              shows: p.shows, episodes: p.episodes, podsPending: false, topShow: nil, podcastsFirst: false, tryThese: nil)
    }

    func searchPage(query: String, filter: String, continuation: String?) async throws -> SearchPage {
        try await searchPageFromAll(query: query, filter: filter, continuation: continuation)
    }

    /// A chip's page built from `searchAll` (fakes without `search_page`).
    func searchPageFromAll(query: String, filter: String, continuation: String?) async throws -> SearchPage {
        var page = SearchPage(filter: filter, query: query, songs: [], items: [], shows: [], episodes: [], continuation: nil)
        guard continuation == nil else { return page }
        let r = try await searchAll(query: query, recordHistory: false)
        switch filter {
        case "songs": page.items = r.songs
        case "artists": page.items = r.artists
        case "albums": page.items = r.albums
        case "playlists": page.items = r.playlists
        case "podcasts": page.shows = (try? await podcastSearch(query: query))?.shows ?? []
        case "episodes": page.episodes = (try? await podcastSearch(query: query))?.episodes ?? []
        default: break
        }
        return page
    }
}
