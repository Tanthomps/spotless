// Jam and collaborative playlists over the share relay (share-relay/, docs in its README).
//
// A channel is a random 16-byte id and a 32-byte key. The relay stores and forwards sealed boxes
// (AES-256-GCM: 12-byte nonce ‖ ciphertext ‖ tag, base64) and never sees the key, which travels
// only in the invite link's #fragment. The web page for a Jam link speaks the same format.
//
// ponytail: this lives in Swift, not the Rust core, so the Mac app has no Jam or collab UI yet.
// Moving `ShareChannel` + the two stores into crates/core is the upgrade path when it should.
import CryptoKit
import Foundation
import Observation
import UIKit

enum ShareRelay {
    static let base = URL(string: "https://spotless-share.tanthompsig.workers.dev")!
}

/// A minimal song on the wire (what a guest needs to play or show it).
struct WireSong: Codable, Equatable, Hashable {
    var videoId: String
    var title: String
    var artists: String
    var thumbnail: String?
    var duration: String?
    init(_ s: SongItem) { videoId = s.videoId; title = s.title; artists = s.artists; thumbnail = s.thumbnail; duration = s.duration }
    var song: SongItem { SongItem(videoId: videoId, title: title, artists: artists, duration: duration, thumbnail: thumbnail) }
}

/// One live channel: a WebSocket to the relay that reconnects, seals what it sends and opens what
/// arrives. `onMessage` gets every message from someone else, in relay order.
@MainActor final class ShareChannel {
    let id: String
    let key: SymmetricKey
    let me: String
    var onMessage: ([String: Any]) -> Void = { _ in }
    var onState: (Bool) -> Void = { _ in }
    /// The last relay message id seen, so a reconnect (or a relaunch) carries on from there.
    var onCursor: (Int) -> Void = { _ in }
    var lastId = 0
    private var task: URLSessionWebSocketTask?
    private var closed = false
    private var ping: Task<Void, Never>?

    init(id: String, keyData: Data, me: String) {
        self.id = id; self.key = SymmetricKey(data: keyData); self.me = me
    }

    static func make(me: String) -> ShareChannel {
        var idBytes = [UInt8](repeating: 0, count: 16), k = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &idBytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &k)
        return ShareChannel(id: idBytes.map { String(format: "%02x", $0) }.joined(), keyData: Data(k), me: me)
    }

    var keyB64url: String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    var fragment: String { "c=\(id)&k=\(keyB64url)" }

    /// hex(SHA-256(key ‖ "relay")): proves the key to the relay without sending it.
    private var token: String {
        var d = key.withUnsafeBytes { Data($0) }
        d.append(Data("relay".utf8))
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    static func parse(_ fragment: String) -> (id: String, key: Data)? {
        var c = URLComponents(); c.query = fragment
        guard let id = c.queryItems?.first(where: { $0.name == "c" })?.value, id.count == 32,
              var k = c.queryItems?.first(where: { $0.name == "k" })?.value else { return nil }
        k = k.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        k += String(repeating: "=", count: (4 - k.count % 4) % 4)
        guard let key = Data(base64Encoded: k), key.count == 32 else { return nil }
        return (id, key)
    }

    func connect() {
        closed = false
        var c = URLComponents(url: ShareRelay.base.appendingPathComponent("c/\(id)/ws"), resolvingAgainstBaseURL: false)!
        c.scheme = "wss"
        c.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "after", value: String(lastId))]
        let t = URLSession.shared.webSocketTask(with: c.url!)
        task = t
        t.resume()
        receive(t)
        onState(true)
        ping?.cancel()
        ping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                self?.task?.send(.string(#"{"type":"ping"}"#)) { _ in }
            }
        }
    }

    func close() {
        closed = true
        ping?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let m):
                    if case .string(let s) = m { self.handle(s) }
                    self.receive(t)
                case .failure:
                    self.onState(false)
                    guard !self.closed else { return }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !self.closed && self.task === t { self.connect() }
                }
            }
        }
    }

    private func handle(_ s: String) {
        guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any], o["type"] as? String == "msg" else { return }
        if let n = o["id"] as? Int, n > lastId { lastId = n; onCursor(n) }
        guard (o["from"] as? String) != me, let box = o["box"] as? String, let data = Data(base64Encoded: box),
              let sealed = try? AES.GCM.SealedBox(combined: data), let plain = try? AES.GCM.open(sealed, using: key),
              let msg = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { return }
        onMessage(msg)
    }

    /// Seal and send; `snap` marks a message new members start from (Jam state, playlist snapshot).
    func send(_ msg: [String: Any], snap: Bool = false) {
        guard let task, let plain = try? JSONSerialization.data(withJSONObject: msg),
              let sealed = try? AES.GCM.seal(plain, using: key), let combined = sealed.combined else { return }
        let env: [String: Any] = ["from": me, "box": combined.base64EncodedString(), "snap": snap]
        guard let d = try? JSONSerialization.data(withJSONObject: env), let s = String(data: d, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    static func encode<T: Encodable>(_ v: T) -> Any? {
        (try? JSONEncoder().encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0) }
    }
    static func decode<T: Decodable>(_ t: T.Type, _ v: Any?) -> T? {
        guard let v, let d = try? JSONSerialization.data(withJSONObject: v) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }
}

/// This device's id on channels (stable per install) and the name others see.
enum ShareIdentity {
    static var me: String {
        if let v = UserDefaults.standard.string(forKey: "share.me") { return v }
        let v = "ios-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        UserDefaults.standard.set(v, forKey: "share.me")
        return v
    }
}

// MARK: Jam

/// Spotify's Jam: the host's queue is the Jam's. Guests (in the app or on the web page) see it,
/// add and remove songs, play/pause and skip; app guests also play along, in step with the host.
@MainActor @Observable final class JamStore {
    struct Member: Codable, Equatable, Hashable { var id: String; var name: String }
    struct State: Codable, Equatable {
        var host: Member
        var items: [WireSong]
        var index: Int
        var posMs: Double
        var at: Double
        var playing: Bool
        var members: [Member]
    }
    enum Role: Equatable { case host, guest }

    private(set) var role: Role?
    private(set) var state: State?
    private(set) var members: [Member] = []
    private(set) var connected = false
    private(set) var link: URL?
    var sheetOpen = false

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var channel: ShareChannel?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastSent: String = ""
    @ObservationIgnored private var lastSentAt = Date.distantPast

    init(app: AppModel) { self.app = app }

    var active: Bool { role != nil }
    var myName: String { app?.localUser ?? "Someone" }

    // host

    func start() {
        guard role == nil, let app else { return }
        let ch = ShareChannel.make(me: ShareIdentity.me)
        attach(ch, role: .host)
        link = URL(string: "\(ShareRelay.base.absoluteString)/j#\(ch.fragment)")
        members = [Member(id: ShareIdentity.me, name: myName)]
        publish(force: true)
        // Publish whenever the queue, the song or play/pause changes, and a heartbeat every 15 s.
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                self?.publish(force: false)
            }
        }
        Haptics.impact(.medium)
        app.showToast("Jam started. Invite friends to listen together.")
    }

    private func snapshot() -> State? {
        guard let app else { return nil }
        let p = app.player
        let items = p.queue.items.map(WireSong.init)
        return State(host: Member(id: ShareIdentity.me, name: myName), items: items, index: p.queue.currentIndex,
                     posMs: p.position * 1000, at: Date().timeIntervalSince1970 * 1000, playing: !p.paused, members: members)
    }

    private func publish(force: Bool) {
        guard role == .host, let s = snapshot() else { return }
        // Position alone isn't news (guests extrapolate from posMs + at); a seek is.
        let key = "\(s.items.map(\.videoId))|\(s.index)|\(s.playing)|\(s.members)"
        let jumped = seekJump(s)
        guard force || key != lastSent || jumped || Date().timeIntervalSince(lastSentAt) > 15 else { return }
        lastSent = key; lastSentAt = Date()
        state = s
        if let v = ShareChannel.encode(s) as? [String: Any] { channel?.send(v.merging(["t": "state"]) { $1 }, snap: true) }
    }

    @ObservationIgnored private var lastPos: (pos: Double, at: Date) = (0, .distantPast)
    private func seekJump(_ s: State) -> Bool {
        defer { lastPos = (s.posMs, Date()) }
        let predicted = lastPos.pos + (s.playing ? Date().timeIntervalSince(lastPos.at) * 1000 : 0)
        return abs(s.posMs - predicted) > 3000 && lastPos.at != .distantPast
    }

    private func hostHandle(_ m: [String: Any]) {
        guard let app else { return }
        switch m["t"] as? String {
        case "hello":
            if let id = m["id"] as? String, !members.contains(where: { $0.id == id }) {
                let name = (m["name"] as? String).map { String($0.prefix(40)) } ?? "Guest"
                members.append(Member(id: id, name: name))
                app.showToast("\(name) joined the Jam")
            }
            publish(force: true)
        case "bye":
            members.removeAll { $0.id == m["id"] as? String }
            publish(force: true)
        case "add":
            if let s = ShareChannel.decode(WireSong.self, m["song"]) { _ = app.player.addToQueue([s.song]) }
        case "remove":
            if let v = m["videoId"] as? String,
               let i = app.player.queue.items.indices.last(where: { $0 > app.player.queue.currentIndex && app.player.queue.items[$0].videoId == v }) {
                app.player.remove(at: i)
            }
        case "cmd":
            switch m["op"] as? String {
            case "next": app.player.skipNext()
            case "prev": app.player.skipPrevious()
            case "play": if app.player.paused { app.player.togglePause() }
            case "pause": if !app.player.paused { app.player.togglePause() }
            default: break
            }
        case "search":
            // Web guests search through the host (YouTube Music needs no key from this side).
            guard let q = m["q"] as? String, let rid = m["rid"] as? String else { return }
            Task {
                let found = (try? await app.core.search(query: String(q.prefix(100)))) ?? []
                let items = found.prefix(12).map(WireSong.init).compactMap { ShareChannel.encode($0) }
                channel?.send(["t": "results", "rid": rid, "items": items])
            }
        default: break
        }
    }

    // guest

    func join(fragment: String) {
        guard let (id, key) = ShareChannel.parse(fragment) else { app?.fail("That Jam link isn't complete."); return }
        if role != nil { leave() }
        let ch = ShareChannel(id: id, keyData: key, me: ShareIdentity.me)
        attach(ch, role: .guest)
        link = URL(string: "\(ShareRelay.base.absoluteString)/j#\(ch.fragment)")
        ch.send(["t": "hello", "id": ShareIdentity.me, "name": myName])
        sheetOpen = true
    }

    private func guestHandle(_ m: [String: Any]) {
        guard let app else { return }
        switch m["t"] as? String {
        case "state":
            guard let s = ShareChannel.decode(State.self, m) else { return }
            let first = state == nil
            state = s; members = s.members
            follow(s, app: app)
            if first { app.showToast("You joined \(s.host.name)'s Jam") }
        case "end":
            app.showToast("\(state?.host.name ?? "The host") ended the Jam")
            detach()
        default: break
        }
    }

    /// Play what the host plays, where the host is: a new song or queue loads it, drift over 2.5 s seeks.
    private func follow(_ s: State, app: AppModel) {
        guard s.items.indices.contains(s.index) else { return }
        let want = (s.posMs + (s.playing ? max(0, Date().timeIntervalSince1970 * 1000 - s.at) : 0)) / 1000
        let p = app.player
        if p.current?.videoId != s.items[s.index].videoId {
            p.play(s.items.map(\.song), at: s.index, context: PlayContext(kind: .song, id: nil, title: "\(s.host.name)'s Jam"), startSecs: want)
            if !s.playing { Task { try? await Task.sleep(nanoseconds: 800_000_000); if !p.paused { p.togglePause() } } }
            return
        }
        if abs(p.position - want) > 2.5 { p.seek(want) }
        if s.playing == p.paused { p.togglePause() }
    }

    /// A guest's play/pause/skip goes to the host, who is the one source of truth.
    func command(_ op: String) {
        if role == .host, let app {
            switch op { case "next": app.player.skipNext(); case "prev": app.player.skipPrevious(); default: app.player.togglePause() }
        } else {
            channel?.send(["t": "cmd", "op": op])
        }
    }

    func add(_ songs: [SongItem]) {
        if role == .host { _ = app?.player.addToQueue(songs); return }
        for s in songs { if let v = ShareChannel.encode(WireSong(s)) { channel?.send(["t": "add", "song": v]) } }
        app?.showToast(songs.count == 1 ? "Added to the Jam" : "Added \(counted(songs.count, "song")) to the Jam")
    }

    func leave() {
        if role == .host { channel?.send(["t": "end"]) } else { channel?.send(["t": "bye", "id": ShareIdentity.me]) }
        detach()
    }

    private func attach(_ ch: ShareChannel, role: Role) {
        channel = ch; self.role = role
        ch.onMessage = { [weak self] m in role == .host ? self?.hostHandle(m) : self?.guestHandle(m) }
        ch.onState = { [weak self] up in self?.connected = up }
        ch.connect()
    }

    private func detach() {
        loop?.cancel(); loop = nil
        let ch = channel
        Task { try? await Task.sleep(nanoseconds: 500_000_000); ch?.close() }
        channel = nil; role = nil; state = nil; members = []; link = nil; sheetOpen = false
    }
}

// MARK: Collaborative playlists

/// A playlist shared with friends: everyone adds and removes songs. Each member keeps an ordinary
/// playlist; this store diffs it against what the channel last agreed on, sends the difference,
/// and applies what others send.
// ponytail: songs are keyed by videoId (a song twice in one playlist is one entry for the channel),
// and order isn't shared: new songs land at the end on every device.
@MainActor @Observable final class CollabStore {
    struct Link: Codable, Equatable {
        var playlistId: String; var channel: String; var key: String; var known: [String]
        /// The last relay message applied here (relaunches carry on from it, never replay).
        var cursor: Int?
    }
    private(set) var links: [String: Link] = [:] // by playlist id

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var channels: [String: ShareChannel] = [:]
    @ObservationIgnored private var busy = Set<String>()

    init(app: AppModel) {
        self.app = app
        if let d = UserDefaults.standard.data(forKey: "collab.links"), let l = try? JSONDecoder().decode([String: Link].self, from: d) { links = l }
    }

    func isCollab(_ playlistId: String) -> Bool { links[playlistId] != nil }

    private func save() {
        if let d = try? JSONEncoder().encode(links) { UserDefaults.standard.set(d, forKey: "collab.links") }
    }

    func inviteLink(_ playlistId: String, name: String) -> URL? {
        guard let l = links[playlistId] else { return nil }
        let n = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "\(ShareRelay.base.absoluteString)/p#c=\(l.channel)&k=\(l.key)&n=\(n)")
    }

    /// Make an own playlist collaborative: a snapshot of its songs goes up first.
    func share(_ playlistId: String) async -> URL? {
        guard let app else { return nil }
        if links[playlistId] == nil {
            guard let page = try? await app.core.getPlaylist(id: playlistId) else { app.fail("Couldn't open that playlist"); return nil }
            let ch = ShareChannel.make(me: ShareIdentity.me)
            let ids = page.items.map(\.videoId)
            links[playlistId] = Link(playlistId: playlistId, channel: ch.id, key: ch.keyB64url, known: ids)
            save()
            wire(ch, playlistId)
            ch.connect()
            ch.send(["t": "snap", "name": page.title ?? "Playlist", "songs": page.items.map(WireSong.init).compactMap { ShareChannel.encode($0) }], snap: true)
        }
        return inviteLink(playlistId, name: app.library.snapshot.playlists.first { $0.id == playlistId }?.name ?? "Playlist")
    }

    /// Joining from a link: a new playlist here, filled from the channel's snapshot as it arrives.
    func join(fragment: String) {
        guard let app, let (id, key) = ShareChannel.parse(fragment) else { app?.fail("That playlist link isn't complete."); return }
        if let existing = links.values.first(where: { $0.channel == id }) {
            app.router.dismissOverlays(); app.router.tab = .library; app.router.paths[.library] = [.playlist(existing.playlistId)]
            return
        }
        var c = URLComponents(); c.query = fragment
        let name = c.queryItems?.first { $0.name == "n" }?.value ?? "Collaborative playlist"
        Task {
            guard let pl = try? await app.core.createPlaylist(name: name) else { app.fail("Couldn't create the playlist"); return }
            let ch = ShareChannel(id: id, keyData: key, me: ShareIdentity.me)
            links[pl.id] = Link(playlistId: pl.id, channel: id, key: ch.keyB64url, known: [])
            save()
            wire(ch, pl.id)
            ch.connect()
            await app.library.refresh()
            app.router.dismissOverlays(); app.router.tab = .library; app.router.paths[.library] = [.playlist(pl.id)]
            app.showToast("You joined \(name)")
        }
    }

    /// Connect every collaborative playlist (on launch and when the app comes back).
    func resume() {
        for l in links.values where channels[l.playlistId] == nil {
            guard let (id, key) = ShareChannel.parse("c=\(l.channel)&k=\(l.key)") else { continue }
            let ch = ShareChannel(id: id, keyData: key, me: ShareIdentity.me)
            wire(ch, l.playlistId)
            ch.connect()
        }
        Task {
            for id in links.keys {
                await push(id)
                await snapshot(id)
            }
        }
    }

    /// A fresh full list, so someone joining later starts from now, not from a log the relay trims.
    private func snapshot(_ playlistId: String) async {
        guard let app, let ch = channels[playlistId], let page = try? await app.core.getPlaylist(id: playlistId) else { return }
        ch.send(["t": "snap", "name": page.title ?? "Playlist", "songs": page.items.map(WireSong.init).compactMap { ShareChannel.encode($0) }], snap: true)
    }

    func leave(_ playlistId: String) {
        channels[playlistId]?.close(); channels[playlistId] = nil
        links[playlistId] = nil; save()
    }

    private func wire(_ ch: ShareChannel, _ playlistId: String) {
        channels[playlistId] = ch
        ch.lastId = links[playlistId]?.cursor ?? 0
        ch.onMessage = { [weak self] m in Task { await self?.apply(m, playlistId) } }
        ch.onCursor = { [weak self] n in
            guard let self, var l = self.links[playlistId] else { return }
            l.cursor = n; self.links[playlistId] = l; self.save()
        }
    }

    /// Others' changes, into this device's copy.
    private func apply(_ m: [String: Any], _ playlistId: String) async {
        guard let app, var l = links[playlistId] else { return }
        switch m["t"] as? String {
        case "snap":
            let songs = ((m["songs"] as? [Any]) ?? []).compactMap { ShareChannel.decode(WireSong.self, $0) }
            let have = Set((try? await app.core.getPlaylist(id: playlistId))?.items.map(\.videoId) ?? [])
            let missing = songs.filter { !have.contains($0.videoId) }.map(\.song)
            if !missing.isEmpty { try? await app.core.addToPlaylist(id: playlistId, songs: missing) }
            l.known = Array(Set(l.known).union(songs.map(\.videoId)))
        case "add":
            guard let s = ShareChannel.decode(WireSong.self, m["song"]), !l.known.contains(s.videoId) else { return }
            try? await app.core.addToPlaylist(id: playlistId, songs: [s.song])
            l.known.append(s.videoId)
        case "remove":
            guard let v = m["videoId"] as? String else { return }
            try? await app.core.removeFromPlaylist(id: playlistId, videoIds: [v])
            l.known.removeAll { $0 == v }
        default: return
        }
        links[playlistId] = l; save()
        await app.library.refresh()
    }

    /// This device's changes, out: the playlist now vs. what the channel last agreed on.
    func push(_ playlistId: String) async {
        guard let app, var l = links[playlistId], let ch = channels[playlistId], !busy.contains(playlistId) else { return }
        busy.insert(playlistId); defer { busy.remove(playlistId) }
        guard let page = try? await app.core.getPlaylist(id: playlistId) else { return }
        let now = page.items.map(\.videoId), nowSet = Set(now), known = Set(l.known)
        for s in page.items where !known.contains(s.videoId) {
            if let v = ShareChannel.encode(WireSong(s)) { ch.send(["t": "add", "song": v]) }
        }
        for v in known where !nowSet.contains(v) { ch.send(["t": "remove", "videoId": v]) }
        l.known = now
        links[playlistId] = l; save()
    }

    /// After any library change: push each collaborative playlist's difference.
    func libraryChanged() {
        Task { for id in links.keys { await push(id) } }
    }
}

/// The invite for a collaborative playlist: the system share sheet with the playlist link.
enum CollabInvite {
    @MainActor static func present(_ link: URL, name: String, app: AppModel) {
        Task {
            // After the naming sheet (or the ··· sheet) has gone.
            try? await Task.sleep(nanoseconds: 500_000_000)
            let vc = UIActivityViewController(activityItems: ["Add songs to \(name) with me on Spotless", link], applicationActivities: nil)
            vc.completionWithItemsHandler = { _, done, _, _ in if done { app.showToast("Invite sent") } }
            guard let top = ShareSheet.topViewController() else { return }
            vc.popoverPresentationController?.sourceView = top.view
            top.present(vc, animated: true)
        }
    }
}
