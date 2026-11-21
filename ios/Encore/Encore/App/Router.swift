// Tabs, one NavigationStack path per tab, the full-screen layers, and `encore://` deep links
// (the desktop `deeplink.rs` hosts — album/artist/playlist — plus screen hosts for screenshots).
import SwiftUI

enum Tab: String, CaseIterable, Hashable {
    case home, search, library, create
    var title: String {
        switch self { case .home: "Home"; case .search: "Search"; case .library: "Your Library"; case .create: "Create" }
    }
}

enum Route: Hashable {
    case album(String)
    case artist(String)
    case playlist(String)
    /// A Home "Your Mix" tile (`dailymix:<artist keys>`, core kind `daily_mix`): id, title,
    /// subtitle, art. Its songs come from `smart_mix`; the tile carries the rest.
    case dailyMix(String, String, String?, String?)
    case liked
    /// A Home shelf's "Show all" grid (gap #27): the `smart_home` shelf id and its title. A route
    /// on the tab's stack, so Back from a page opened in the grid returns to the grid.
    case shelf(String, String)
    /// "Go to … radio" as a page (lane D1's `radio_tracks`): kind (song | artist | album | playlist), id, name.
    case radio(String, String, String?)
    /// The local listening history (`lib_recent_tracks`).
    case history
    /// Listening stats (`listening_stats`): range chips, top artists / tracks / albums, activity.
    case stats
    case searchResults(String)
    case mood(String, String) // params, title
    // podcasts
    case show(String)
    case episode(String)
    case yourEpisodes
    /// stream: audiobooks — a book page (Internet Archive id).
    case audiobook(String)
    case newEpisodes
    // smart2
    case madeForYou
    case whatsNew
    // Search › Browse (stream ios-sync2)
    case charts
    case newReleases
    // library
    case folder(String)
    // settings
    case settings
    case settingsPage(SettingsPage)
}

/// What a `playlist?find=…&sort=…` link asks the playlist page to open with (consumed once).
struct PlaylistFindRequest: Equatable {
    var id: String
    var query: String?
    var sort: PlaylistViewSort?
}

/// What a `discography/<artist id>` link asks the artist page to open (consumed once).
struct DiscographyRequest: Equatable {
    var artistId: String
    var filter: Discography.Filter?
}

/// Spotify iOS Settings sub-pages.
enum SettingsPage: String, Hashable, CaseIterable {
    case account, contentDisplay = "content", playback, privacy, audioQuality = "quality", equalizer = "eq", storage
    case dataSaver = "datasaver", recoverPlaylists = "recover", about
    case podcasts
    var title: String {
        switch self {
        case .account: "Account"
        case .contentDisplay: "Content and display"
        case .playback: "Playback"
        case .privacy: "Privacy and social"
        case .audioQuality: "Media quality"
        case .equalizer: "Equalizer"
        case .storage: "Storage"
        case .dataSaver: "Data-saving and offline"
        case .recoverPlaylists: "Recover playlists"
        case .about: "About"
        case .podcasts: "Podcasts"
        }
    }
}

@MainActor @Observable
final class Router {
    var tab: Tab = .home
    var paths: [Tab: [Route]] = [.home: [], .search: [], .library: [], .create: []]
    var nowPlayingOpen = false
    /// encore://debug: synthetic audio-session events (DebugAudio.swift).
    var debugOpen = false
    var queueOpen = false
    var lyricsOpen = false
    var searchFocused = false
    /// The avatar's side menu (Spotify: What's new, Settings and privacy).
    var sideMenuOpen = false
    /// The floating Create menu over the tab bar (Screens/JamCollab.swift).
    var createOpen = false
    var searchQuery = ""
    /// Deep link `encore://search?q=…&chip=podcasts`: the results chip to start on.
    var searchCategory: String?
    /// Deep link `encore://search?q=…&suggest=1`: show the query's typeahead as if just typed.
    var searchSuggest = false
    /// Deep link `encore://home?chip=podcasts`.
    var homeChip: String?
    /// Deep link `encore://home?scroll=end`: Home scrolls to its last shelf once loaded (screenshots).
    var homeScrollEnd = false
    /// Deep link `encore://nowplaying?cards=1`: scroll Now Playing to its cards.
    var npShowCards = 0
    /// Bumped when the active tab is re-tapped at its root: screens scroll to top.
    var scrollToTopSerial: [Tab: Int] = [:]
    /// Deep link `spotless://playlist/<id>?find=<q>&sort=<title|artist|album|recent|custom>`: the
    /// playlist page opens with Find in playlist showing (and that query) or in that order.
    var playlistFind: PlaylistFindRequest?
    /// Deep link `spotless://discography/<artist id>[?filter=albums|singles|compilations]`.
    var discography: DiscographyRequest?

    func binding(_ tab: Tab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab] ?? [] }, set: { self.paths[tab] = $0 })
    }

    func push(_ r: Route) { paths[tab, default: []].append(r) }

    /// Spotify: re-tapping the active tab pops to root, then scrolls to top. On Search's root the
    /// re-tap also puts the cursor in the search field (gap #31).
    func select(_ t: Tab) {
        if t == tab {
            if !(paths[t] ?? []).isEmpty { paths[t] = [] } else {
                scrollToTopSerial[t, default: 0] += 1
                if t == .search { searchFocused = true }
            }
        } else {
            tab = t
        }
    }

    func open(_ item: BrowseItem) {
        switch item.kind {
        case .album: push(.album(item.id))
        case .artist: push(.artist(item.id))
        case .playlist where isDailyMixId(item.id): push(.dailyMix(item.id, item.title, item.subtitle, item.thumbnail))
        case .playlist: push(item.id == likedPlaylistId ? .liked : .playlist(item.id))
        case .song: break
        case .podcast: push(.show(item.id))
        case .episode: push(.episode(item.id))
        case .audiobook: push(.audiobook(item.id))
        }
    }

    func push(_ show: PodcastShow) { push(.show(show.id)) }

    func dismissOverlays() {
        nowPlayingOpen = false; queueOpen = false; lyricsOpen = false; sideMenuOpen = false; createOpen = false
    }

    /// encore://album/<id>, artist/<id>, playlist/<id>, liked, home, search[?q=], library, nowplaying,
    /// queue, lyrics, create, play/<playlist id>[?index=n&open=1], show/<id>, episode/<id>,
    /// your-episodes, new-episodes, made-for-you, whats-new, folder/<id>, settings[/<page>], import,
    /// sleep, speed, play-episode/<id>[?open=1], playlist/<id>?find=<q>&sort=<order>,
    /// discography/<artist id>[?filter=<chip>]
    /// The app's own URL schemes: `spotless`, and `encore` from before the rename (kept so older
    /// links, shares and tests keep opening).
    static let appSchemes: Set<String> = ["spotless", "encore"]

    func handle(_ url: URL, app: AppModel) {
        guard let scheme = url.scheme?.lowercased(), Router.appSchemes.contains(scheme) else { openWebLink(url, app: app); return }
        let host = url.host ?? ""
        let id = url.pathComponents.dropFirst().first
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func param(_ k: String) -> String? { q.first { $0.name == k }?.value }
        switch host {
        case "home", "search", "library":
            dismissOverlays()
            let t: Tab = host == "home" ? .home : host == "search" ? .search : .library
            tab = t; paths[t] = []
            if t == .search, let text = param("q") { searchQuery = text; searchFocused = true }
            if t == .search, param("chip") == "podcasts" { searchCategory = "Podcasts & Shows" }
            if t == .search, param("chip") == "audiobooks" { searchCategory = "Audiobooks" }
            if t == .search, param("chip") == "videos" { searchCategory = "Videos" }
            // `&suggest=1`: the query as if just typed, its suggestions showing (screenshots).
            if t == .search, param("suggest") == "1" { searchSuggest = true }
            if t == .home, let c = param("chip") { homeChip = c.capitalized }
            if t == .home, param("scroll") == "end" { homeScrollEnd = true }
            if t == .home, param("synchint") == "1" { app.devices.forceHint = true } // the one-time link hint (screenshots)
            if t == .search, param("focus") == "1" { searchFocused = true }
            if t == .search, param("results") != nil { searchFocused = false; paths[t] = [.searchResults(param("results") ?? "")] }
            if t == .library {
                app.libraryFilter = param("filter")
                app.librarySubFilter = param("sub")
                app.librarySearch = param("q")
                if let sort = param("sort"), let v = LibrarySort.allCases.first(where: { "\($0)" == sort }) { app.librarySort = v }
                if param("grid") == "1" { app.libraryGrid = true }
            }
        case "album": if let id { dismissOverlays(); push(.album(id)) }
        case "artist": if let id { dismissOverlays(); push(.artist(id)) }
        case "playlist":
            if let id {
                dismissOverlays()
                if param("find") != nil || param("sort") != nil {
                    playlistFind = PlaylistFindRequest(id: id, query: param("find"), sort: param("sort").flatMap(PlaylistViewSort.init(rawValue:)))
                }
                push(id == likedPlaylistId ? .liked : .playlist(id))
            }
        case "discography":
            // The artist page, then its full discography over it (ArtistView pushes it).
            if let id {
                dismissOverlays()
                discography = DiscographyRequest(artistId: id, filter: param("filter").flatMap(Discography.Filter.init(rawValue:)))
                push(.artist(id))
            }
        case "shelf":
            if let id {
                dismissOverlays()
                tab = .home; paths[.home] = []
                push(.shelf(id.removingPercentEncoding ?? id, param("title") ?? ""))
            }
        case "liked": dismissOverlays(); push(.liked)
        case "show": if let id { dismissOverlays(); push(.show(id.removingPercentEncoding ?? id)) }
        case "episode": if let id { dismissOverlays(); push(.episode(id.removingPercentEncoding ?? id)) }
        case "audiobook": if let id { dismissOverlays(); push(.audiobook(id.removingPercentEncoding ?? id)) } // stream: audiobooks
        case "your-episodes": dismissOverlays(); push(.yourEpisodes)
        case "new-episodes": dismissOverlays(); push(.newEpisodes)
        case "made-for-you": dismissOverlays(); push(.madeForYou)
        case "whats-new": dismissOverlays(); push(.whatsNew)
        case "charts": dismissOverlays(); tab = .search; push(.charts)
        case "new-releases": dismissOverlays(); tab = .search; push(.newReleases)
        case "history": dismissOverlays(); push(.history) // stream ios-p2: Recents
        case "stats": dismissOverlays(); push(.stats)
        case "effects": app.sheet = .effects
        case "about-recommendations": app.sheet = .aboutRecommendations
        case "folder": if let id { dismissOverlays(); tab = .library; push(.folder(id)) }
        case "settings":
            dismissOverlays()
            push(.settings)
            if let id, let page = SettingsPage(rawValue: id) { push(.settingsPage(page)) }
        case "import":
            ImportFlow.shared.handle(Dictionary(q.compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a }), app: app)
            app.importOpen = true
        case "menu-side": sideMenuOpen = true
        case "sleep":
            nowPlayingOpen = true
            if let m = param("min").flatMap(Int.init) { app.settings.setSleep(minutes: m) }
            app.sheet = .sleepTimer
        case "speed": nowPlayingOpen = true; app.sheet = .speed
        case "chapters": nowPlayingOpen = true; app.sheet = .chapters
        case "play-episode":
            guard let id else { break }
            Task {
                guard let e = try? await app.core.podcastEpisode(id: id) else { return }
                app.player.play([e.song], at: 0, context: PlayContext(kind: .song, id: nil, title: e.showTitle))
                if param("pause") == "1" { try? await Task.sleep(nanoseconds: 300_000_000); app.player.togglePause() }
                if param("open") == "1" { nowPlayingOpen = true }
            }
        case "nowplaying": nowPlayingOpen = true; if param("cards") == "1" { npShowCards += 1 }
        case "queue":
            nowPlayingOpen = true; queueOpen = true
            if param("smart") == "1" { Task { _ = await app.settings.setSmartShuffle(true) } }
        case "lyrics": nowPlayingOpen = true; lyricsOpen = true
        case "create": app.sheet = .create
        case "debug":
            // spotless://debug?audio=<DebugAudio name>: fire it without the menu (on-device checks).
        #if DEBUG
            if let a = param("audio").flatMap(DebugAudio.Action.init(rawValue:)) { DebugAudio.fire(a) } else { debugOpen = true }
        #else
            break // Release: a web page must not be able to fire fake audio interruptions.
        #endif
        case "playsearch":
            // encore://playsearch?q=<query>[&index=n&open=1]: search the real catalogue and play.
            let query = param("q") ?? ""
            let index = Int(param("index") ?? "0") ?? 0
            Task {
                // Like a user tapping "Try again": YouTube's bot wall fails searches in bursts.
                var found: [SongItem] = []
                for attempt in 0..<5 where found.isEmpty {
                    if attempt > 0 { try? await Task.sleep(nanoseconds: 6_000_000_000) }
                    found = (try? await app.core.search(query: query)) ?? []
                }
                let songs = found
                guard !songs.isEmpty else { return }
                // A search pick, as tapping that row would: the song, then Autoplay.
                app.player.playSingle(songs[min(index, songs.count - 1)], from: query)
                if param("open") == "1" { nowPlayingOpen = true }
            }
        case "sort": app.sheet = .sort
        case "download": // encore://download/<collection id>: start downloading it (screenshots, tests)
            if let id {
                let kind = id == likedPlaylistId ? "liked" : id.hasPrefix("MPRE") ? "album" : "playlist"
                app.downloads.add(DownloadCollection(id: id, kind: kind, title: id == likedPlaylistId ? "Liked Songs" : id))
                DownloadKeeper.shared.userStartedDownload(title: id == likedPlaylistId ? "Liked Songs" : id)
            }
        case "offline": app.downloads.set(DownloadSettingsPatch(offlineMode: param("on") != "0"))
        case "new-playlist": app.sheet = .newPlaylist
        case "new-folder": app.sheet = .newFolder
        case "toast": app.showToast(param("text") ?? "Added to Liked Songs", action: "Change")
        case "menu":
            if let s = app.player.current { app.sheet = .track(s, context: nil) }
        case "play":
            let pid = id ?? "VLLM"
            let index = Int(param("index") ?? "0") ?? 0
            Task {
                guard let page = try? await app.core.getPlaylist(id: pid) else { return }
                app.player.play(page.items, at: index, context: PlayContext(kind: pid == likedPlaylistId ? .liked : .playlist, id: pid, title: page.title ?? ""))
                if param("pause") == "1" { try? await Task.sleep(nanoseconds: 300_000_000); app.player.togglePause() }
                if let s = param("seek"), let t = Double(s) { try? await Task.sleep(nanoseconds: 400_000_000); app.player.seek(t) }
                if param("smart") == "1" { try? await Task.sleep(nanoseconds: 300_000_000); _ = await app.settings.setSmartShuffle(true) }
                if param("open") == "1" { nowPlayingOpen = true }
            }
        default: handleMore(host: host, id: id, param: param, app: app, url: url)
        }
    }
}
