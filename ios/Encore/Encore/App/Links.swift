// Links into the app (stream ios-polish):
// - spotless:// (or the older encore://) song/<videoId>, encore://add-to-playlist[/<videoId>], encore://share[/<kind>/<id>],
//   encore://open?url=<https link>.
// - Web links, as they arrive from a universal link, a pasted link in Search, or `-deeplink`:
//   music.youtube.com / youtube.com / youtu.be (watch, playlist, browse/MPRE…, browse/VL…, channel)
//   open the same screen. open.spotify.com: a track plays its match, an album or artist opens its
//   matched page, a playlist or profile opens the Spotify import (`openSpotify`).
import SwiftUI

/// Where a link points inside Spotless.
enum LinkTarget: Equatable {
    case song(String)
    case album(String)
    case artist(String)
    case playlist(String)
    case spotify(String)

    /// Parse an https link (or a bare `youtu.be/…` paste). nil: not one of ours.
    static func parse(_ raw: String) -> LinkTarget? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let u = URLComponents(string: s), let host = u.host?.lowercased() else { return nil }
        let path = u.path.split(separator: "/").map(String.init)
        func q(_ k: String) -> String? { u.queryItems?.first { $0.name == k }?.value }
        switch host {
        case "open.spotify.com", "spotify.link":
            return .spotify(s)
        case "youtu.be":
            return path.first.map(LinkTarget.song)
        case "music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com":
            switch path.first {
            case "watch": return q("v").map(LinkTarget.song)
            case "playlist":
                guard let list = q("list") else { return nil }
                return list.hasPrefix("OLAK5uy_") ? .album(list) : .playlist("VL" + list)
            case "browse":
                guard let id = path.dropFirst().first else { return nil }
                if id.hasPrefix("MPRE") { return .album(id) }
                if id.hasPrefix("VL") { return .playlist(id) }
                if id.hasPrefix("UC") { return .artist(id) }
                return .playlist(id)
            case "channel": return path.dropFirst().first.map(LinkTarget.artist)
            case "shorts", "embed", "live": return path.dropFirst().first.map(LinkTarget.song)
            default: return nil
            }
        default: return nil
        }
    }
}

extension Router {
    /// http(s) links: open the matching screen, or say we can't.
    func openWebLink(_ url: URL, app: AppModel) {
        if url.isFileURL {
            // A Spotify export (zip / json / csv) opened in Spotless from Files or the share sheet.
            ImportFlow.shared.handle(["file": url.absoluteString], app: app)
            app.importOpen = true
            return
        }
        guard let t = LinkTarget.parse(url.absoluteString) else { return }
        open(t, app: app)
    }

    func open(_ t: LinkTarget, app: AppModel) {
        dismissOverlays()
        app.sheet = nil
        switch t {
        case .album(let id): push(.album(id))
        case .artist(let id): push(.artist(id))
        case .playlist(let id): push(.playlist(id))
        case .song(let id): playSong(id, app: app)
        case .spotify(let link): openSpotify(link, app: app)
        }
    }

    /// A Spotify link (desktop `openSpotifyLink`): a track plays its YouTube Music match on its own
    /// (Autoplay behind it), an album or artist opens the matched page, a playlist or profile goes
    /// to the import. The core decides which (`import_resolve`).
    private func openSpotify(_ link: String, app: AppModel) {
        func toImport() {
            ImportFlow.shared.handle(["step": "preview", "link": link], app: app)
            app.importOpen = true
        }
        Task {
            let resolved: SpotifyResolved
            do { resolved = try await app.core.importResolve(link: link) } catch {
                // Not a link the core reads (a short spotify.link, say): the import knows more.
                if (error as? CoreFailure)?.message == "not_spotify" { return toImport() }
                return app.showToast("Couldn't find that on YouTube Music")
            }
            switch resolved {
            case .playlist: toImport()
            case .album(let id): push(.album(id))
            case .artist(let id): push(.artist(id))
            case .song(let s):
                app.player.playSingle(s)
                nowPlayingOpen = true
            }
        }
    }

    /// A shared song: play it (autoplay carries on as radio) and show Now Playing.
    private func playSong(_ videoId: String, app: AppModel) {
        Task {
            do {
                let s = try await app.core.song(videoId: videoId)
                // A single: the linked song only, then Autoplay seeded from it.
                app.player.playSingle(s)
                nowPlayingOpen = true
            } catch {
                app.showToast("Couldn't open that song")
            }
        }
    }

    /// encore:// hosts added by this stream (called from `handle`'s default branch).
    func handleMore(host: String, id: String?, param: (String) -> String?, app: AppModel, url: URL? = nil) {
        switch host {
        case "song": if let id { open(.song(id), app: app) }
        case "open": if let raw = param("url"), let t = LinkTarget.parse(raw) { open(t, app: app) }
        case "add-to-playlist":
            // encore://add-to-playlist[/<videoId>]: the picker for that song (default: the current one).
            Task {
                var song = app.player.current
                // Chained after a play link: wait for the track to land (real core: a search first).
                for _ in 0..<60 where song == nil && id == nil {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    song = app.player.current
                }
                if let id { song = (try? await app.core.song(videoId: id)) ?? song }
                if let song { app.sheet = .addToPlaylist([song]) }
            }
        case "play-album":
            // encore://play-album/<id>[?index=n]: play an album (offline: its downloaded copy).
            guard let id else { break }
            let index = Int(param("index") ?? "0") ?? 0
            Task {
                guard let page = await app.loadAlbum(id), !page.items.isEmpty else { return }
                let i = min(index, page.items.count - 1)
                app.player.play(page.items, at: i, context: PlayContext(kind: .album, id: id, title: page.title ?? ""))
            }
        case "jam":
            // spotless://jam?c=<channel>&k=<key>: join a Jam (from the web page's "Open in Spotless").
            app.router.dismissOverlays()
            if let q = url?.query { app.jam.join(fragment: q) }
        case "collab":
            // spotless://collab?c=…&k=…&n=<name>: join a collaborative playlist.
            if let q = url?.query { app.collab.join(fragment: q) }
        case "pair":
            // spotless://pair?v=1&code=…&addr=… (the QR another device shows, opened by the camera).
            app.router.dismissOverlays()
            let raw = url?.absoluteString ?? ""
            if let qr = CodeEntry.pairLink(in: raw) { app.devices.openJoin(qr: qr) }
        case "link-device":
            // spotless://link-device[?step=show|enter|scan|success&code=12&error=<core error>]: the
            // linking sheet (side menu, Settings; screenshots and tests reach each state).
            let d = app.devices
            switch param("step") {
            case "show": d.open(.showCode)
            case "enter": d.open(.enterCode)
            case "scan": d.open(.scan)
            case "success": d.open(.success)
            default: d.open()
            }
            if let c = param("code") { d.digits = c }
            if let e = param("error") { d.error = e == "local_network" ? .localNetwork : PairingError.from(e) }
            if let end = param("end") { d.codeEnd = end == "tries" ? .tooManyTries : .expired }
        case "link-welcome": app.devices.welcomeOpen = true
            // encore://share: the current song's share sheet (screenshots).
            if let s = app.player.current { ShareSheet.present(.song(s), app: app) }
        default: break
        }
    }
}
