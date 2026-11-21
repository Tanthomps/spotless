// Create menu (Spotify: a floating panel above the tab bar, the Create tab turned into a white ✕),
// the Jam sheet and its pill above the mini player. The logic is App/JamCollabStores.swift.
import SwiftUI

/// Spotify's Create panel: rows with a 48 pt round icon, title and one line of help.
struct CreateMenuOverlay: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let open = app.router.createOpen
        ZStack(alignment: .bottom) {
            if open {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { close() }
                    .transition(.opacity)
                    .accessibilityHidden(true)
                VStack(spacing: 0) {
                    row("music-note", "Playlist", "Create a playlist with songs or episodes", id: "create-playlist") { app.sheet = .newPlaylist }
                    row("user-plus", "Collaborative playlist", "Create a playlist together with friends", id: "create-collab") { app.sheet = .newCollab }
                    row("users-three", "Jam", "Listen together from anywhere", id: "create-jam") { startJam() }
                    row("folder", "Folder", "Keep related playlists together", id: "create-folder") { app.sheet = .newFolder }
                }
                .padding(.vertical, Space.s)
                .background(SheetGlass(radius: 28))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .padding(.horizontal, Space.s)
                .padding(.bottom, Metrics.tabBarHeight + 12)
                .transition(Motion.reduce ? .opacity : .modifier(active: PopEffect(scale: 0.95, blur: 6, opacity: 0), identity: PopEffect(scale: 1, blur: 0, opacity: 1)))
                .accessibilityIdentifier("create-menu")
            }
        }
        .animation(open ? Motion.spring : Motion.exit, value: open)
    }

    private func close() { app.router.createOpen = false }

    private func startJam() {
        if app.jam.active { app.jam.sheetOpen = true; return }
        guard app.player.hasTrack else { app.showToast("Play something first, then start a Jam"); return }
        app.jam.start()
        app.jam.sheetOpen = true
    }

    private func row(_ icon: String, _ title: String, _ sub: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            close()
            action()
        } label: {
            HStack(spacing: Space.l) {
                Icon(name: icon, size: 26).frame(width: 52, height: 52).background(Circle().fill(Color.white.opacity(0.1)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.font(17, .bold))
                    Text(sub).font(Typo.font(14)).foregroundStyle(Palette.subdued).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.l).frame(height: 70).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .foregroundStyle(Palette.text)
        .accessibilityIdentifier(id)
    }
}

/// "Jam · 3 people" above the mini player while a Jam is on; opens the Jam sheet.
struct JamPill: View {
    @Environment(AppModel.self) private var app
    var body: some View {
        let jam = app.jam!
        Button { jam.sheetOpen = true } label: {
            HStack(spacing: 6) {
                Icon(name: "users-three", size: 14)
                Text(jam.role == .host ? "Your Jam" : "\(jam.state?.host.name ?? "Someone")'s Jam").font(Typo.font(13, .bold))
                Text("· \(counted(max(1, jam.members.count), "person", "people"))").font(Typo.font(13))
                if !jam.connected { ProgressView().controlSize(.mini).tint(.black) }
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(Palette.accent))
        }
        .buttonStyle(PressScale())
        .accessibilityIdentifier("jam-pill")
    }
}

/// The Jam: who's in, the invite (link, QR, share), play controls for guests, add songs, leave/end.
struct JamSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [SongItem] = []
    @State private var searching = false
    @State private var added = Set<String>()

    var body: some View {
        let jam = app.jam!
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(jam.role == .host ? "Your Jam" : "\(jam.state?.host.name ?? "Someone")'s Jam").font(Typo.font(24, .bold))
                    Text(jam.connected ? "Everyone hears the same queue." : "Connecting…").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                }
                // Who's in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Space.s) {
                        ForEach(jam.members, id: \.id) { m in
                            Text(m.name).font(Typo.font(13, .semibold)).padding(.horizontal, 12).frame(height: 30).glassCapsule()
                        }
                    }
                }
                if let link = jam.link {
                    HStack(spacing: Space.l) {
                        QRTile(payload: link.absoluteString, size: 120)
                        VStack(alignment: .leading, spacing: Space.s) {
                            Text("Invite friends").font(Typo.font(16, .bold))
                            Text("They can join in Spotless or in any browser.").font(Typo.font(13)).foregroundStyle(Palette.subdued)
                            HStack(spacing: Space.s) {
                                ShareLink(item: link) {
                                    Text("Share link").font(Typo.font(14, .bold)).foregroundStyle(.black)
                                        .padding(.horizontal, 14).frame(height: 36).background(Capsule().fill(Palette.accent))
                                }
                                .accessibilityIdentifier("jam-share")
                                Button {
                                    UIPasteboard.general.url = link
                                    app.showToast("Link copied")
                                } label: {
                                    Text("Copy").font(Typo.font(14, .bold)).padding(.horizontal, 14).frame(height: 36)
                                        .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                                }
                            }
                        }
                    }
                }
                // Playing now, and controls (guests' go to the host)
                if let s = jam.state, s.items.indices.contains(s.index) {
                    let cur = s.items[s.index]
                    HStack(spacing: Space.m) {
                        ArtImage(url: cur.thumbnail, px: 144, radius: Radius.xs).frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cur.title).font(Typo.rowTitle).lineLimit(1)
                            Text(cur.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                        }
                        Spacer()
                        Button { jam.command(s.playing ? "pause" : "play") } label: {
                            PlayPauseGlyph(playing: s.playing, size: 36).foregroundStyle(.black).background(Circle().fill(.white))
                        }
                        .accessibilityLabel(s.playing ? "Pause" : "Play")
                        Button { jam.command("next") } label: { SkipGlyph(forward: true, size: 26).frame(width: 40, height: 40) }
                            .accessibilityLabel("Next")
                    }
                }
                // Add songs
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("Add songs").font(Typo.font(18, .bold))
                    HStack(spacing: Space.s) {
                        Icon(name: "magnifying-glass", size: 18).foregroundStyle(Color(hex: "#121212"))
                        TextField("", text: $query, prompt: Text("Search songs").foregroundStyle(Color(hex: "#535353")))
                            .font(Typo.font(15, .medium)).foregroundStyle(.black).submitLabel(.search)
                            .onSubmit(search)
                            .accessibilityIdentifier("jam-search")
                    }
                    .padding(.horizontal, Space.m).frame(height: 44)
                    .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(.white))
                    if searching { SkeletonRows(count: 3) }
                    ForEach(results, id: \.videoId) { s in
                        HStack(spacing: Space.m) {
                            ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: 44, height: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.title).font(Typo.rowTitle).lineLimit(1)
                                Text(s.artists).font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                            }
                            Spacer()
                            Button {
                                jam.add([s]); added.insert(s.videoId)
                            } label: {
                                IconSwap(name: added.contains(s.videoId) ? "check-circle" : "plus-circle", fill: added.contains(s.videoId), size: 26)
                                    .foregroundStyle(added.contains(s.videoId) ? Palette.accent : Palette.text).frame(width: 44, height: 44)
                            }
                            .accessibilityLabel("Add \(s.title) to the Jam")
                        }
                    }
                }
                Button(role: .destructive) {
                    jam.leave()
                    dismiss()
                } label: {
                    Text(jam.role == .host ? "End Jam" : "Leave Jam").font(Typo.font(15, .bold)).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity).frame(height: 48).overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                }
                .accessibilityIdentifier("jam-leave")
            }
            .padding(Space.xl)
        }
        .foregroundStyle(Palette.text)
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        Task {
            results = (try? await app.core.search(query: q)).map { Array($0.prefix(12)) } ?? []
            searching = false
            if results.isEmpty { app.showToast("No songs found") }
        }
    }
}
