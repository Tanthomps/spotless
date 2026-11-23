// Share (Spotify iOS: Share in every sheet and in Now Playing → the system share sheet).
// The shared item is the music.youtube.com link, which opens for anyone; a "Copy Spotless link"
// activity copies the spotless:// link, which opens the same screen in Spotless (Links.swift).
import AVFoundation
import SwiftUI
import UIKit

/// What is being shared, and its two links.
struct ShareLinks: Equatable {
    var title: String
    var web: URL?
    var app: URL
    /// A song that can be saved as a file (Share › Download).
    var song: SongItem? = nil

    static func song(_ s: SongItem) -> ShareLinks {
        if s.isEpisode == true {
            return ShareLinks(title: s.title, web: nil, app: encore("episode", s.videoId))
        }
        return ShareLinks(title: "\(s.title) · \(s.artists)",
                          web: URL(string: "https://music.youtube.com/watch?v=\(s.videoId)"),
                          app: encore("song", s.videoId),
                          song: s.videoId.hasPrefix("LOCAL:") ? nil : s)
    }

    static func item(_ c: BrowseItem) -> ShareLinks {
        let id = c.id
        switch c.kind {
        case .song: return .song(c.asSong)
        case .album:
            return ShareLinks(title: c.title, web: URL(string: "https://music.youtube.com/browse/\(esc(id))"), app: encore("album", id))
        case .artist:
            return ShareLinks(title: c.title, web: URL(string: "https://music.youtube.com/channel/\(esc(id))"), app: encore("artist", id))
        case .playlist:
            if id == likedPlaylistId { return ShareLinks(title: "Liked Songs", web: nil, app: encore("liked", nil)) }
            // Own playlists live on this phone only: the link opens them here.
            let web = id.hasPrefix("LOCALPLAYLIST") || id.hasPrefix("MFY_") ? nil
                : URL(string: "https://music.youtube.com/playlist?list=\(esc(id.hasPrefix("VL") ? String(id.dropFirst(2)) : id))")
            return ShareLinks(title: c.title, web: web, app: encore("playlist", id))
        case .podcast: return ShareLinks(title: c.title, web: nil, app: encore("show", id))
        case .episode: return ShareLinks(title: c.title, web: nil, app: encore("episode", id))
        case .audiobook: return ShareLinks(title: c.title, web: URL(string: "https://archive.org/details/\(esc(id))"), app: encore("audiobook", id))
        }
    }

    static func show(_ s: PodcastShow) -> ShareLinks {
        ShareLinks(title: s.title, web: s.feedUrl.flatMap(URL.init(string:)), app: encore("show", s.id))
    }
    static func episode(_ e: PodcastEpisode) -> ShareLinks {
        ShareLinks(title: e.title, web: nil, app: encore("episode", e.id))
    }

    private static func esc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) ?? s
    }
    private static func encore(_ host: String, _ id: String?) -> URL {
        URL(string: "spotless://\(host)\(id.map { "/" + esc($0) } ?? "")")!
    }
}

/// The link item, with a title for the share sheet's header (`LPLinkMetadata`-free: the system
/// fetches the page preview itself for https links).
final class ShareItemSource: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }
    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { url }
    func activityViewController(_ c: UIActivityViewController, itemForActivityType t: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ c: UIActivityViewController, subjectForActivityType t: UIActivity.ActivityType?) -> String { title }
}

/// "Copy Spotless link": the spotless:// link to the same screen.
final class CopyEncoreLinkActivity: UIActivity {
    let link: URL
    init(link: URL) { self.link = link }
    override var activityType: UIActivity.ActivityType? { .init("app.spotlessmusic.ios.copy-link") }
    override var activityTitle: String? { "Copy Spotless link" }
    override var activityImage: UIImage? { UIImage(systemName: "link") }
    override class var activityCategory: UIActivity.Category { .action }
    override func canPerform(withActivityItems items: [Any]) -> Bool { true }
    override func perform() {
        UIPasteboard.general.url = link
        activityDidFinish(true)
    }
}

/// "Download": the song as "Artist - Title.m4a", then the Files picker to choose where it goes.
final class DownloadSongActivity: UIActivity {
    let song: SongItem
    let app: AppModel
    init(song: SongItem, app: AppModel) { self.song = song; self.app = app }
    override var activityType: UIActivity.ActivityType? { .init("app.spotlessmusic.ios.download-song") }
    override var activityTitle: String? { "Download (.m4a)" }
    override var activityImage: UIImage? { UIImage(systemName: "arrow.down.circle") }
    override class var activityCategory: UIActivity.Category { .action }
    override func canPerform(withActivityItems items: [Any]) -> Bool { true }
    override func perform() {
        activityDidFinish(true)
        let (song, app) = (song, app)
        Task { @MainActor in await SongExport.run(song, app: app) }
    }
}

@MainActor enum SongExport {
    static func fileName(_ s: SongItem) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let raw = [s.artists, s.title].filter { !$0.isEmpty }.joined(separator: " - ")
        let clean = raw.components(separatedBy: bad).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        return String((clean.isEmpty ? "Song" : clean).prefix(150)) + ".m4a"
    }

    static func run(_ s: SongItem, app: AppModel) async {
        app.showToast("Saving \(s.title)…")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let raw = dir.appendingPathComponent("raw.m4a")
        let url = dir.appendingPathComponent(fileName(s))
        do {
            try await app.core.exportSong(videoId: s.videoId, to: raw.path)
        } catch {
            app.showToast("Couldn't save \(s.title): \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: dir)
            return
        }
        // YouTube's AAC is a fragmented (DASH) MP4 that some editors mis-read: rewrap it as a plain
        // .m4a (passthrough, nothing re-encoded). If that fails, hand over the file as it came.
        if !(await remux(raw, to: url)) {
            try? FileManager.default.moveItem(at: raw, to: url)
        }
        try? FileManager.default.removeItem(at: raw)
        try? await Task.sleep(nanoseconds: 300_000_000) // the share sheet's dismissal
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = Cleanup.shared
        Cleanup.shared.dirs.append(dir)
        ShareSheet.topViewController()?.present(picker, animated: true)
    }

    static func remux(_ src: URL, to dst: URL) async -> Bool {
        guard let ex = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else { return false }
        if #available(iOS 18, *) {
            do { try await ex.export(to: dst, as: .m4a); return true } catch { return false }
        }
        ex.outputURL = dst
        ex.outputFileType = .m4a
        await ex.export()
        return ex.status == .completed
    }

    /// Drops the temp copy once Files has its own.
    final class Cleanup: NSObject, UIDocumentPickerDelegate {
        static let shared = Cleanup()
        var dirs: [URL] = []
        private func clear() { dirs.forEach { try? FileManager.default.removeItem(at: $0) }; dirs = [] }
        func documentPicker(_ c: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { clear() }
        func documentPickerWasCancelled(_ c: UIDocumentPickerViewController) { clear() }
    }
}

enum ShareSheet {
    /// Set by the last presentation; tests and the share deep link read it.
    @MainActor static var lastLinks: ShareLinks?

    /// Present the system share sheet over whatever is on screen (sheets included).
    @MainActor static func present(_ links: ShareLinks, app: AppModel) {
        lastLinks = links
        Haptics.impact(.light)
        let primary = links.web ?? links.app
        let vc = UIActivityViewController(activityItems: [ShareItemSource(url: primary, title: links.title)],
                                          applicationActivities: [CopyEncoreLinkActivity(link: links.app)]
                                            + (links.song.map { [DownloadSongActivity(song: $0, app: app)] } ?? []))
        vc.excludedActivityTypes = [.assignToContact, .addToReadingList, .saveToCameraRoll, .print]
        vc.completionWithItemsHandler = { type, done, _, _ in
            guard done else { return }
            if type == .copyToPasteboard || type?.rawValue == "app.spotlessmusic.ios.copy-link" {
                Task { @MainActor in app.showToast("Link copied") }
            }
        }
        guard let top = topViewController() else { return }
        vc.popoverPresentationController?.sourceView = top.view
        top.present(vc, animated: true)
    }

    /// After an action sheet row: wait for the sheet to finish dismissing, then present.
    @MainActor static func presentAfterSheet(_ links: ShareLinks, app: AppModel) {
        Task { try? await Task.sleep(nanoseconds: 450_000_000); present(links, app: app) }
    }

    @MainActor static func topViewController() -> UIViewController? {
        let w = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
        var top = w?.rootViewController
        while let p = top?.presentedViewController, !p.isBeingDismissed { top = p }
        return top
    }
}
