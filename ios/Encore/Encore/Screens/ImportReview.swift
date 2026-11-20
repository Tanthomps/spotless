// The review step of the Spotify import (stream ios-import-review; simplified by stream onboard).
// The summary leads: "N songs matched ✓" and Looks good (`import_create`). Behind a quiet link,
// one list of the uncertain and not-found songs (and every match on request); tap a song for its
// other candidates, a YouTube Music search, or Leave out. Nothing is written before Looks good;
// a pick is remembered for later imports.
import SwiftUI

/// One track in review (`import_rows`, crates/core import.rs `ReviewRow`).
struct ImportRow: Codable, Hashable, Identifiable {
    var key: String
    var title: String
    var artists: String
    var album: String?
    var durationMs: Int?
    var tier: String // matched | check | missing
    var pick: SongItem?
    /// Empty for matched rows (the core leaves them out; there can be thousands).
    var candidates: [SongItem]
    var id: String { key }
}

extension RealCoreClient {
    func importRows(tier: String) async throws -> [ImportRow] { try await call("import_rows", ["tier": tier]) }
    func importPick(key: String, song: SongItem?) async throws -> ImportSnapshot {
        try await call("import_pick", ["key": key, "song": song])
    }
}

extension MockCoreClient {
    /// The end of the simulated matching: rows for each tier, as the core answers them. Called
    /// with the lock held.
    func mockReview(_ snap: ImportSnapshot) -> ImportSnapshot {
        var s = snap
        s.phase = "review"
        let songs = pool.isEmpty ? [] : (0..<max(s.total, 1)).map { pool[$0 % pool.count] }
        var rows: [ImportRow] = []
        for (i, song) in songs.enumerated() {
            let secs = durationSecs(song.duration) ?? 200
            let key = "sp\(i)"
            if i < s.check {
                // An extended or live upload, the studio song second.
                var odd = song
                odd.videoId = song.videoId + "-x"; odd.title = song.title + " (Extended Mix)"; odd.duration = mmss((secs + 95) * 1000)
                let other = pool[(i + 7) % max(pool.count, 1)]
                rows.append(ImportRow(key: key, title: song.title, artists: song.artists, album: song.album, durationMs: secs * 1000,
                                      tier: "check", pick: odd, candidates: [odd, song, other]))
            } else if i < s.check + s.missing {
                rows.append(ImportRow(key: key, title: "Unreleased Demo \(i)", artists: "Nobody Known", album: nil, durationMs: 151_000,
                                      tier: "missing", pick: nil, candidates: []))
            } else {
                rows.append(ImportRow(key: key, title: song.title, artists: song.artists, album: song.album, durationMs: secs * 1000,
                                      tier: "matched", pick: song, candidates: []))
            }
        }
        fs.importRows = rows
        return s
    }

    func importRows(tier: String) async throws -> [ImportRow] {
        withLock { fs.importRows.filter { $0.tier == tier }.map { tier == "matched" ? ImportRow(key: $0.key, title: $0.title, artists: $0.artists, album: $0.album, durationMs: $0.durationMs, tier: $0.tier, pick: $0.pick, candidates: []) : $0 } }
    }

    func importPick(key: String, song: SongItem?) async throws -> ImportSnapshot {
        try withLock {
            guard var s = fs.importSnap, s.phase == "review", let i = fs.importRows.firstIndex(where: { $0.key == key }) else {
                throw MockError.missing("gone")
            }
            fs.importRows[i].tier = song == nil ? "missing" : "matched"
            fs.importRows[i].pick = song
            s.matched = fs.importRows.filter { $0.tier == "matched" }.count
            s.check = fs.importRows.filter { $0.tier == "check" }.count
            s.missing = fs.importRows.filter { $0.tier == "missing" }.count
            fs.importSnap = s
            return s
        }
    }

    func importCreate(names: [Int: String], local: Bool) async throws {
        let s = try withLock { () -> ImportSnapshot in
            guard var s = fs.importSnap, s.phase == "review" else { throw MockError.missing("gone") }
            let skipped = fs.importRows.filter { $0.pick == nil || $0.tier == "missing" }.count
            let local = local || !mockSignedIn
            s.phase = "done"
            s.results = s.lists.enumerated().map { i, l in
                ImportResult(kind: l.kind, name: names[i] ?? l.name, id: local ? "LOCALPLAYLIST:1" : "PLmockimport\(i)", local: local,
                             added: max(l.count, 25), missing: skipped, removed: 0)
            }
            fs.importSnap = s
            fs.settings[SettingKey.importDone] = "true"
            return s
        }
        UserDefaults.standard.set("true", forKey: "mock." + SettingKey.importDone)
        emit("import-progress", s)
    }
}

private func durationSecs(_ d: String?) -> Int? {
    guard let d else { return nil }
    let parts = d.split(separator: ":").compactMap { Int($0) }
    guard !parts.isEmpty else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

/// 3:45 from milliseconds.
func mmss(_ ms: Int?) -> String? {
    guard let ms, ms > 0 else { return nil }
    let s = ms / 1000
    return "\(s / 60):" + String(format: "%02d", s % 60)
}

// MARK: flow

extension ImportFlow {
    /// Matching is done: the summary ("N songs matched", Looks good). The rows load when asked for.
    func openReview(_ app: AppModel) async {
        settled = [:]
        tiers = [:]
        let lists = snapshot?.lists ?? []
        name = lists.count == 1 ? Self.listName(lists[0]) : ""
        onAccount = false
        go(.review)
    }

    /// A list's name as the import shows it (the desktop's `listName`).
    static func listName(_ l: ImportSnapshot.L) -> String {
        l.kind == "liked" ? "Liked Songs" : l.kind == "history" ? "Listening history" : l.name
    }

    /// Only Liked Songs and history: nothing to name or place (the desktop's `onlyLiked`).
    var onlyLiked: Bool { (snapshot?.lists ?? []).allSatisfy { $0.kind == "liked" || $0.kind == "history" } }

    /// The rows that need a look: uncertain first, then not found.
    func openCheck(_ app: AppModel) async {
        go(.check)
        let s = snapshot
        if (s?.check ?? 0) > 0 { await loadRows(app, tier: "check") }
        if (s?.missing ?? 0) > 0 { await loadRows(app, tier: "missing") }
        if (s?.check ?? 0) + (s?.missing ?? 0) == 0 { await loadRows(app, tier: "matched") }
    }

    /// One tier's rows (`import_rows`). Kept as loaded: a row settled here stays where it was.
    func loadRows(_ app: AppModel, tier: String) async {
        guard tiers[tier] == nil else { return }
        rowsLoading = true
        defer { rowsLoading = false }
        do { tiers[tier] = try await app.core.importRows(tier: tier) } catch {
            self.error = friendlyError(error, "The songs couldn't be loaded")
        }
    }

    /// A song for the row (kept from now on, in later imports too), or `nil` to leave it out.
    func choose(_ row: ImportRow, _ song: SongItem?, _ app: AppModel) async {
        do {
            snapshot = try await app.core.importPick(key: row.key, song: song)
            for (t, list) in tiers {
                if let i = list.firstIndex(where: { $0.key == row.key }), let song { tiers[t]?[i].pick = song }
            }
            settled[row.key] = song != nil
            choosing = nil
        } catch { self.error = friendlyError(error, "That change couldn't be saved") }
    }

    /// Write everything (`import_create`); the progress step follows it to Done. Like the desktop:
    /// Liked Songs carries its playlist name, a single playlist the name typed here, and signed
    /// in it goes where you picked (signed out always on this phone).
    func create(_ app: AppModel) async {
        guard !creating else { return }
        creating = true
        var names: [Int: String] = [:]
        let lists = snapshot?.lists ?? []
        for (i, l) in lists.enumerated() where l.kind == "liked" { names[i] = "Liked Songs from Spotify" }
        let typed = name.trimmingCharacters(in: .whitespaces)
        if lists.count == 1, lists[0].kind == "playlist", !typed.isEmpty { names[0] = typed }
        let local = !app.account.signedIn || !onAccount
        do { try await app.core.importCreate(names: names, local: local) } catch {
            creating = false
            self.error = friendlyError(error, "The import couldn't be saved")
            return
        }
        go(.progress)
        // Follow it to Done here too: the progress view's own task can lose the race with the
        // step change and never start (seen live), which left the screen on "Adding…".
        if live { Task { await poll(app) } }
    }

    /// Songs that go in: matched plus the uncertain ones (their best pick), minus those left out.
    var readyCount: Int {
        let s = snapshot
        return (s?.matched ?? 0) + (s?.check ?? 0)
    }

    /// What "Looks good" adds, in one line: "5 playlists, your Liked Songs and listening history".
    var addsLine: String {
        let lists = snapshot?.lists ?? []
        let playlists = lists.filter { $0.kind == "playlist" || $0.kind == "album" }.count
        var parts: [String] = []
        if playlists > 0 { parts.append(playlists == 1 ? "1 playlist" : "\(playlists) playlists") }
        if lists.contains(where: { $0.kind == "liked" }) { parts.append("your Liked Songs") }
        if lists.contains(where: { $0.kind == "history" }) { parts.append("your listening history") }
        guard !parts.isEmpty else { return "" }
        let joined = parts.count > 1 ? parts.dropLast().joined(separator: ", ") + " and " + parts.last! : parts[0]
        return "Adds \(joined) to Your Library."
    }

    /// The quiet link under Looks good.
    var checkTitle: String {
        let s = snapshot
        let check = s?.check ?? 0, missing = s?.missing ?? 0
        if check > 0 { return "Check \(check) uncertain one\(check == 1 ? "" : "s")" }
        if missing > 0 { return "See \(missing) not found" }
        return "See all songs"
    }

    /// The label "Looks good" carried before stream onboard (kept for callers and tests).
    var createTitle: String {
        let lists = snapshot?.lists ?? []
        let playlists = lists.filter { $0.kind == "playlist" || $0.kind == "album" }.count
        if playlists > 1 { return "Create \(playlists) playlists" }
        if playlists == 1 { return "Create playlist" }
        return lists.contains { $0.kind == "liked" } ? "Add to Liked Songs" : "Add listening history"
    }
}

// MARK: review summary

/// "N songs matched ✓" and one button. The details sit behind a quiet link (ImportCheckStep).
struct ImportReviewStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow

    var body: some View {
        let s = flow.snapshot
        let missing = s?.missing ?? 0
        VStack(spacing: 0) {
            Spacer(minLength: Space.xl)
            let none = flow.readyCount == 0
            Circle().fill(none ? Palette.elevatedHighlight : Palette.accent).frame(width: 88, height: 88)
                .overlay(Icon(name: none ? "warning-circle" : "check", size: 44).foregroundStyle(none ? Palette.text : .black))
                .padding(.bottom, Space.xl)
                .accessibilityHidden(true)
            OnboardHeader(title: none ? "No songs matched" : "\(flow.readyCount.formatted()) song\(flow.readyCount == 1 ? "" : "s") matched",
                          line: none ? "Check the songs to pick matches by hand, or try another link." : flow.addsLine, center: true)
            if missing > 0 {
                Text("\(missing) \(missing == 1 ? "isn't" : "aren't") on YouTube Music and will be left out.")
                    .font(Typo.font(14)).foregroundStyle(Palette.dim).multilineTextAlignment(.center)
                    .padding(.top, Space.m)
            }
            Spacer(minLength: Space.xl)
            options(s)
            Spacer(minLength: 0)
            if let e = flow.error {
                Text(e).font(Typo.font(14)).foregroundStyle(Palette.negative).padding(.bottom, Space.s)
            }
            VStack(spacing: Space.s) {
                OnboardPrimaryButton(title: "Looks good", busy: flow.creating, enabled: flow.readyCount > 0) { Task { await flow.create(app) } }
                    .accessibilityIdentifier("import-create")
                OnboardTextButton(title: flow.checkTitle) { Task { await flow.openCheck(app) } }
                    .accessibilityIdentifier("import-check")
            }
            .padding(.bottom, Space.s)
        }
        .padding(.horizontal, Space.xl)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-review")
    }

    /// The desktop's review options: rename a single imported playlist, and signed in, where the
    /// playlists go ("On this iPhone" or "On YouTube Music").
    @ViewBuilder private func options(_ s: ImportSnapshot?) -> some View {
        let single = (s?.lists.count ?? 0) == 1 && !flow.onlyLiked
        let place = app.account.signedIn && !flow.onlyLiked
        if single || place {
            VStack(alignment: .leading, spacing: Space.m) {
                if single {
                    TextField("", text: $flow.name, prompt: Text("Playlist name").foregroundStyle(Palette.dim))
                        .font(Typo.font(16)).foregroundStyle(Palette.text)
                        .padding(.horizontal, Space.m).frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: Radius.s).fill(Palette.tinted))
                        .accessibilityLabel("Playlist name")
                        .accessibilityIdentifier("import-name")
                }
                if place {
                    Text("Save playlists").font(Typo.font(14)).foregroundStyle(Palette.subdued)
                    HStack(spacing: Space.s) {
                        Chip(title: "On this iPhone", selected: !flow.onAccount) { flow.onAccount = false }
                            .accessibilityIdentifier("import-where-device")
                            .accessibilityAddTraits(!flow.onAccount ? .isSelected : [])
                        Chip(title: "On YouTube Music", selected: flow.onAccount) { flow.onAccount = true }
                            .accessibilityIdentifier("import-where-account")
                            .accessibilityAddTraits(flow.onAccount ? .isSelected : [])
                    }
                }
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.l).fill(Palette.highlight))
        }
    }
}

// MARK: check

/// The songs worth a look, one list: "Not sure", then "Not found", then on request every match.
struct ImportCheckStep: View {
    @Environment(AppModel.self) private var app
    @Bindable var flow: ImportFlow

    var body: some View {
        let s = flow.snapshot
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                OnboardHeader(title: "Check your songs", line: "Tap a song to pick a different match.")
                    .padding(.horizontal, Space.xl).padding(.top, Space.s).padding(.bottom, Space.l)
                section("check", "Not sure")
                section("missing", "Not on YouTube Music")
                section("matched", "Matched")
                if flow.rowsLoading {
                    SkeletonRows(count: 4)
                } else if let e = flow.error {
                    VStack(spacing: Space.s) {
                        Text(e).font(Typo.font(14)).foregroundStyle(Palette.negative)
                        Button("Try again") { flow.error = nil; Task { await flow.openCheck(app) } }
                            .font(Typo.font(14, .bold)).foregroundStyle(Palette.text)
                            .accessibilityIdentifier("import-check-retry")
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                }
                if flow.tiers["matched"] == nil, (s?.matched ?? 0) > 0, !flow.rowsLoading {
                    OnboardTextButton(title: "Show \((s?.matched ?? 0).formatted()) matched songs") {
                        Task { await flow.loadRows(app, tier: "matched") }
                    }
                    .accessibilityIdentifier("import-show-matched")
                    .padding(.top, Space.l)
                }
            }
            .padding(.bottom, Space.l)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            OnboardPrimaryButton(title: "Done") { flow.go(.review) }
                .accessibilityIdentifier("import-check-done")
                .padding(.horizontal, Space.xl).padding(.top, Space.m).padding(.bottom, Space.s)
                .background(Palette.base)
        }
        .sheet(item: $flow.choosing) { row in
            ImportChooseSheet(flow: flow, row: row)
                .environment(app)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(Palette.base)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-check-list")
    }

    @ViewBuilder private func section(_ tier: String, _ title: String) -> some View {
        if let rows = flow.tiers[tier], !rows.isEmpty {
            Text("\(title) · \(rows.count.formatted())").font(Typo.font(16, .bold))
                .padding(.horizontal, Space.xl).padding(.top, Space.l).padding(.bottom, Space.xs)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("import-section-\(tier)")
            ForEach(rows) { row in
                ImportReviewRow(row: row, mark: flow.settled[row.key],
                                open: { flow.choosing = row },
                                keep: { Task { await flow.choose(row, row.pick, app) } })
            }
        }
    }
}

/// One Spotify track and the YouTube Music song it became. Tap: other candidates (and Leave out).
/// An uncertain row has one quiet "Looks right" check on the right.
struct ImportReviewRow: View {
    let row: ImportRow
    /// `true` kept ("Looks right" or a new pick), `false` left out, `nil` untouched.
    let mark: Bool?
    let open: () -> Void
    let keep: () -> Void

    private var out: Bool { mark == false }

    var body: some View {
        HStack(spacing: Space.m) {
            Button(action: open) {
                HStack(spacing: Space.m) {
                    art
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(Typo.rowTitle).foregroundStyle(Palette.text).lineLimit(1)
                        matchLine
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Choose another match")
            .accessibilityIdentifier("import-row-\(row.key)")
            if row.tier == "check", row.pick != nil, mark == nil {
                Button(action: keep) { Icon(name: "check-circle", size: 28).foregroundStyle(Palette.subdued).frame(width: 44, height: 44) }
                    .accessibilityLabel("Looks right")
                    .accessibilityIdentifier("import-keep-\(row.key)")
            } else if mark == true {
                Icon(name: "check-circle", fill: true, size: 28).foregroundStyle(Palette.accent).frame(width: 44, height: 44)
                    .accessibilityLabel("Kept")
            } else if row.pick == nil || out {
                Icon(name: "caret-right", size: 16).foregroundStyle(Palette.dim).frame(width: 44, height: 44)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Space.xl).padding(.trailing, Space.m)
        .frame(minHeight: 68)
        .opacity(out ? 0.45 : 1)
    }

    @ViewBuilder private var art: some View {
        if let p = row.pick, !out {
            ArtImage(url: p.thumbnail, px: 144, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
        } else {
            RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.elevatedHighlight)
                .frame(width: Metrics.rowArt, height: Metrics.rowArt)
                .overlay(Icon(name: "music-note", size: 20).foregroundStyle(Palette.dim))
        }
    }

    /// Who it is on Spotify, then what it became here (or why there is nothing).
    @ViewBuilder private var matchLine: some View {
        Group {
            if out {
                Text("Left out").foregroundStyle(Palette.dim)
            } else if let p = row.pick {
                let differs = p.title.lowercased() != row.title.lowercased()
                Text(differs ? "Matched to \(p.title)" : [row.artists, p.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                    .foregroundStyle(Palette.subdued)
            } else {
                Text("\(row.artists) • Tap to search").foregroundStyle(Palette.subdued)
            }
        }
        .font(Typo.font(14)).lineLimit(1)
    }
}


// MARK: candidates

/// The other songs a track could be, and a YouTube Music search (or a pasted YouTube link).
struct ImportChooseSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var flow: ImportFlow
    let row: ImportRow

    @State private var query = ""
    @State private var results: [SongItem]?
    @State private var searching = false
    @State private var searchFailed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Choose a match").font(Typo.font(16, .bold)).accessibilityAddTraits(.isHeader)
                HStack {
                    Button("Cancel") { dismiss() }.font(Typo.font(16)).foregroundStyle(Palette.text)
                    Spacer()
                }
            }
            .padding(.horizontal, Space.gutter).frame(height: 56)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("From Spotify").font(Typo.font(13, .bold)).foregroundStyle(Palette.subdued)
                        Text(row.title).font(Typo.font(20, .bold)).fixedSize(horizontal: false, vertical: true)
                        Text([row.artists, row.album, mmss(row.durationMs)].compactMap { $0 }.joined(separator: " • "))
                            .font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
                    searchField.padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                    Text("Paste a YouTube link if the song is only up as a video.")
                        .font(Typo.font(12)).foregroundStyle(Palette.dim).padding(.horizontal, Space.gutter).padding(.bottom, Space.l)
                    Text(results == nil ? "Suggestions" : "Results").font(Typo.font(16, .bold))
                        .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                    if let e = flow.error {
                        Text(e).font(Typo.font(14)).foregroundStyle(Palette.negative)
                            .padding(.horizontal, Space.gutter).padding(.bottom, Space.s)
                            .accessibilityIdentifier("import-choose-error")
                    }
                    let list = results ?? candidates
                    if list.isEmpty {
                        Text(searching ? "Searching…" : searchFailed ? "Couldn't search. Check your connection." : results == nil ? "No suggestions. Try a search." : "No songs found.")
                            .font(Typo.rowSubtitle).foregroundStyle(Palette.subdued)
                            .frame(maxWidth: .infinity).padding(.vertical, Space.xl)
                    }
                    ForEach(Array(list.enumerated()), id: \.offset) { _, s in candidateRow(s) }
                    if row.pick != nil, flow.settled[row.key] != false {
                        Button { Task { await flow.choose(row, nil, app) } } label: {
                            Text("Leave this song out").font(Typo.font(15, .bold)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 24).frame(height: 44)
                                .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                        }
                        .buttonStyle(PressScale())
                        .frame(maxWidth: .infinity).padding(.top, Space.xl)
                        .accessibilityIdentifier("import-leave-out")
                    }
                }
                .padding(.bottom, Space.xxl)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .foregroundStyle(Palette.text)
        .onAppear { query = "\(row.title) \(row.artists)"; flow.error = nil }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("import-choose")
    }

    /// The current pick first, then the core's other candidates.
    private var candidates: [SongItem] {
        var seen = Set<String>()
        return ([row.pick].compactMap { $0 } + row.candidates).filter { seen.insert($0.videoId).inserted }
    }

    private var searchField: some View {
        HStack(spacing: Space.s) {
            Icon(name: "magnifying-glass", size: 18).foregroundStyle(Palette.subdued)
            TextField("", text: $query, prompt: Text("Search YouTube Music").foregroundStyle(Palette.subdued))
                .font(Typo.font(14)).focused($focused).submitLabel(.search).tint(Palette.accent)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await search() } }
                .accessibilityLabel("Search YouTube Music")
                .accessibilityIdentifier("import-search")
            if searching { ProgressView().tint(Palette.subdued) } else if !query.isEmpty {
                Button { query = ""; results = nil } label: { Icon(name: "x", size: 16).foregroundStyle(Palette.subdued) }
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Space.m).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: Radius.m, style: .continuous).fill(Palette.elevatedHighlight))
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        searching = true
        searchFailed = false
        defer { searching = false }
        do {
            if let id = youTubeVideoId(q), let s = try? await app.core.song(videoId: id) { results = [s]; return }
            results = try await app.core.search(query: q)
        } catch {
            results = []
            searchFailed = !FriendlyError.isCancellation(error)
        }
    }

    private func candidateRow(_ s: SongItem) -> some View {
        let current = s.videoId == row.pick?.videoId && flow.settled[row.key] != false
        return HStack(spacing: Space.m) {
            Button { Task { await flow.choose(row, s, app) } } label: {
                HStack(spacing: Space.m) {
                    ArtImage(url: s.thumbnail, px: 144, radius: Radius.xs).frame(width: Metrics.rowArt, height: Metrics.rowArt)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.title).font(Typo.rowTitle).foregroundStyle(current ? Palette.accentText : Palette.text).lineLimit(1)
                        Text([s.artists, s.album, s.duration].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " • "))
                            .font(Typo.rowSubtitle).foregroundStyle(Palette.subdued).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if current { Icon(name: "check-circle", fill: true, size: 22).foregroundStyle(Palette.accent) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(current ? .isSelected : [])
            .accessibilityIdentifier("import-candidate-\(s.videoId)")
            Button {
                app.player.playSingle(s)
            } label: { Icon(name: "play-circle", size: 28).foregroundStyle(Palette.subdued).frame(width: 40, height: 44) }
                .accessibilityLabel("Play \(s.title)")
        }
        .padding(.leading, Space.gutter).padding(.trailing, Space.s)
        .frame(height: Metrics.rowHeight)
    }
}

/// The video id in a pasted YouTube / YouTube Music link (watch?v=, youtu.be/, shorts/).
func youTubeVideoId(_ text: String) -> String? {
    guard let c = URLComponents(string: text.trimmingCharacters(in: .whitespaces)), let host = c.host?.lowercased(),
          host.contains("youtu") else { return nil }
    if let v = c.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty { return v }
    let parts = c.path.split(separator: "/").map(String.init)
    if host.hasSuffix("youtu.be"), let id = parts.first { return id }
    if parts.first == "shorts", parts.count > 1 { return parts[1] }
    return nil
}
