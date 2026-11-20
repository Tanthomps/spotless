// Lane P1: "Show credits" (SYNC-GAPS §2, the desktop's `kit/CreditsDialog.svelte`). The song, then
// each role YouTube Music credits ("Performed by", "Written by", "Produced by") with its people,
// then "Source". A name YouTube links to a channel opens that artist and has Follow; any other
// name searches for it. Data: `song_credits`, one fetch per song per session (`CreditsCache`).
import SwiftUI
import UIKit

/// Credits don't change while the app runs: one answer per song, shared by the sheet and the Now
/// Playing card. A failure isn't kept, so the next ask tries again.
@MainActor
final class CreditsCache {
    static let shared = CreditsCache()
    private var done: [String: SongCredits] = [:]
    private var running: [String: Task<SongCredits, Error>] = [:]

    func cached(_ videoId: String) -> SongCredits? { done[videoId] }

    func load(_ song: SongItem, core: CoreClient) async throws -> SongCredits {
        if let hit = done[song.videoId] { return hit }
        let t = running[song.videoId] ?? Task { try await core.songCredits(song) }
        running[song.videoId] = t
        defer { running[song.videoId] = nil }
        let c = try await t.value
        done[song.videoId] = c
        return c
    }

    func reset() { done = [:]; running = [:] }
}

/// Opening a credited name: the artist page when YouTube links one, else a search for the name.
@MainActor func openCreditName(_ app: AppModel, name: String, artistId: String?) {
    let link: String
    if let artistId {
        link = "spotless://artist/\(artistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? artistId)"
    } else {
        link = "spotless://search?q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)"
    }
    if let u = URL(string: link) { app.router.handle(u, app: app) }
}

/// The outline Follow / Following pill (Spotify's, as on About the artist).
struct FollowPill: View {
    @Environment(AppModel.self) private var app
    let name: String
    let artistId: String
    var body: some View {
        let following = app.library.isSaved(artistId)
        Button(following ? "Following" : "Follow") {
            Haptics.impact(.light)
            app.library.toggleSaved(BrowseItem(kind: .artist, id: artistId, title: name, subtitle: "Artist"))
        }
        .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
        .padding(.horizontal, 16).frame(height: 32)
        .overlay(Capsule().stroke(following ? Palette.text : Palette.muted, lineWidth: 1))
        .buttonStyle(.plain)
        .accessibilityLabel(following ? "Following \(name)" : "Follow \(name)")
        .accessibilityIdentifier("credits-follow")
    }
}

struct CreditsSheet: View {
    @Environment(AppModel.self) private var app
    let song: SongItem
    /// Close the sheet (it is presented from UIKit, over any other sheet).
    var close: () -> Void = {}
    @State private var credits: SongCredits?
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Credits").font(Typo.font(16, .bold)).frame(maxWidth: .infinity)
                    .padding(.top, Space.xl).padding(.bottom, Space.l)
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title).font(Typo.font(22, .bold)).lineLimit(2)
                    Text(song.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                .padding(.bottom, Space.xl)
                content
            }
            .padding(.horizontal, Space.gutter)
            .padding(.bottom, Space.xxl)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(Palette.text)
        .accessibilityIdentifier("credits-sheet")
        .task(id: song.videoId) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let credits {
            if credits.sections.isEmpty {
                Text("YouTube Music has no credits for this song.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
            } else {
                VStack(alignment: .leading, spacing: Space.xl) {
                    ForEach(Array(credits.sections.enumerated()), id: \.offset) { _, s in
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(s.title).font(Typo.font(16, .bold)).padding(.bottom, Space.xs)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(Array(s.people.enumerated()), id: \.offset) { _, p in person(p) }
                        }
                    }
                    if let src = credits.source, !src.isEmpty {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text("Source").font(Typo.font(16, .bold))
                            Text(src).font(Typo.font(14)).foregroundStyle(Palette.subdued)
                        }
                    }
                }
            }
        } else if failed {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Couldn't load the credits.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                Button { failed = false; Task { await load() } } label: {
                    Text("Try again").font(Typo.font(14, .bold)).foregroundStyle(.black)
                        .padding(.horizontal, 24).frame(height: 40).background(Capsule().fill(.white))
                }
                .buttonStyle(PressScale())
                .accessibilityIdentifier("credits-retry")
            }
        } else {
            SkeletonRows(count: 4).padding(.top, Space.l)
                .accessibilityIdentifier("credits-loading")
        }
    }

    private func person(_ p: SongCredits.Person) -> some View {
        HStack(spacing: Space.m) {
            Button {
                close()
                openCreditName(app, name: p.name, artistId: p.artistId)
            } label: {
                Text(p.name).font(Typo.rowTitle).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("credits-name")
            if let id = p.artistId { FollowPill(name: p.name, artistId: id) }
        }
    }

    private func load() async {
        do { credits = try await CreditsCache.shared.load(song, core: app.core) } catch { failed = true }
    }
}

enum CreditsPresenter {
    /// Present the credits over whatever is on screen (after an action sheet has gone, so wait).
    @MainActor static func present(_ song: SongItem, app: AppModel, afterSheet: Bool = true) {
        Task {
            if afterSheet { try? await Task.sleep(nanoseconds: 450_000_000) }
            guard let top = ShareSheet.topViewController() else { return }
            weak var hostRef: UIViewController?
            let view = CreditsSheet(song: song) { hostRef?.dismiss(animated: true) }
                .environment(app)
                .background(SheetGlass().ignoresSafeArea())
                .preferredColorScheme(.dark)
            let host = UIHostingController(rootView: view)
            hostRef = host
            host.view.backgroundColor = .clear
            host.modalPresentationStyle = .pageSheet
            if let s = host.sheetPresentationController {
                s.detents = [.medium(), .large()]
                s.prefersGrabberVisible = true
                s.preferredCornerRadius = Radius.glassSheet
            }
            top.present(host, animated: true)
        }
    }
}
