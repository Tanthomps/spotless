// Stream ios-p2: Settings › Recover playlists (desktop magic-d4 `settings/RecoverPlaylists.svelte`).
// A deleted playlist stays recoverable for 30 days, not only while its Undo toast is up. Each row
// has its song count and the days left; Restore puts it back in Your Library.
import SwiftUI

struct RecoverPlaylistsSettings: View {
    @Environment(AppModel.self) private var app
    @State private var list: [DeletedPlaylist]?
    @State private var failed = false
    @State private var busy: String?

    var body: some View {
        SettingsNote(text: "Playlists you delete can be restored for 30 days.")
            .padding(.top, Space.m)
        if let list {
            if list.isEmpty {
                VStack(spacing: Space.s) {
                    Text("No deleted playlists").font(Typo.font(16, .bold))
                    Text("Playlists you delete show up here for 30 days.").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                }
                .frame(maxWidth: .infinity).padding(.top, Space.xxl)
                .accessibilityIdentifier("recover-empty")
            }
            ForEach(list) { p in row(p) }
        } else {
            EntityLoadState(failed: failed) { Task { await load() } }
        }
        Color.clear.frame(height: 0).task { await load() }
    }

    private func row(_ p: DeletedPlaylist) -> some View {
        HStack(spacing: Space.m) {
            ArtImage(url: p.thumbnail, px: 160, radius: Radius.xs).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(p.name).font(Typo.font(16)).lineLimit(1)
                Text(Self.meta(p)).font(Typo.font(13)).foregroundStyle(Palette.subdued).lineLimit(1)
            }
            Spacer(minLength: Space.s)
            Button { Task { await restore(p) } } label: {
                Text("Restore").font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                    .padding(.horizontal, Space.l).frame(height: 32)
                    .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
            }
            .disabled(busy == p.id)
            .opacity(busy == p.id ? 0.5 : 1)
            .accessibilityIdentifier("restore-\(p.id)")
        }
        .padding(.horizontal, Space.gutter).frame(minHeight: 64)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recover-row")
    }

    /// "12 songs • 29 days left".
    static func meta(_ p: DeletedPlaylist, now: Date = .now) -> String {
        let days = max(0, Int(((Double(p.purgeAt) - now.timeIntervalSince1970) / 86_400).rounded(.up)))
        return "\(counted(p.count, "song")) • \(counted(days, "day")) left"
    }

    private func load() async {
        failed = false
        do { list = try await app.core.deletedPlaylists() } catch { failed = true }
    }

    private func restore(_ p: DeletedPlaylist) async {
        busy = p.id
        defer { busy = nil }
        do {
            try await app.core.restorePlaylist(id: p.id)
            withAnimation(Motion.quick) { list?.removeAll { $0.id == p.id } }
            await app.library.refresh()
            app.showToast("Restored \(p.name)", action: "View") { [app] in
                app.router.dismissOverlays()
                app.router.tab = .library
                app.router.paths[.library] = [.playlist(p.id)]
            }
        } catch {
            app.showToast("Couldn't restore this playlist. Try again.")
        }
    }
}
