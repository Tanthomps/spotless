// Library folders (a pushed page that is the same list, titled with the folder name, with a ···
// menu to rename or delete it) and the naming screen for a new playlist or folder (Spotify: "Give
// your playlist a name"), which also renames a folder. Deleting a folder keeps its playlists and
// offers Undo (`lib_folder_delete` / `lib_folder_restore`, stream ios-p2).
import SwiftUI

struct FolderView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var menuOpen = false
    @State private var renaming = false

    private var folder: Folder? { app.library.snapshot.folders?.first { $0.id == id } }

    private var items: [LibItem] {
        let members = folder?.items ?? []
        let all = LibraryRows.all(app).filter { members.contains($0.id) }
        return LibraryRows.sort(all, app.librarySort == .custom ? .custom : app.librarySort)
    }

    var body: some View {
        let list = items
        VStack(spacing: 0) {
            HStack(spacing: Space.s) {
                Button { dismiss() } label: { Icon(name: "caret-left", size: 22).frame(width: 34, height: 34) }
                    .accessibilityLabel("Back").accessibilityIdentifier("back")
                Text(folder?.name ?? "Folder").font(Typo.font(18, .bold)).lineLimit(1)
                Spacer()
                Button { menuOpen = true } label: { Icon(name: "dots-three", size: 24).frame(width: 34, height: 34) }
                    .accessibilityLabel("More options").accessibilityIdentifier("folder-menu")
                Button { app.sheet = .newPlaylist } label: { Icon(name: "plus", size: 24) }
                    .accessibilityLabel("Create playlist")
            }
            .padding(.horizontal, Space.s + 2)
            .padding(.vertical, Space.s)
            ScrollView {
                HStack(spacing: 6) {
                    Icon(name: "arrows-down-up", size: 14)
                    Text(app.librarySort.rawValue).font(Typo.font(13, .semibold))
                    Spacer()
                }
                .padding(.horizontal, Space.gutter).padding(.vertical, Space.s)
                .contentShape(Rectangle())
                .onTapGesture { app.sheet = .sort }
                .accessibilityAddTraits(.isButton)
                LazyVStack(spacing: 0) {
                    ForEach(list) { LibraryRow(item: $0) }
                }
                if list.isEmpty {
                    VStack(spacing: Space.s) {
                        Text("This folder is empty").font(Typo.font(16, .bold))
                        Text("Add playlists to it from their menu.").font(Typo.meta).foregroundStyle(Palette.subdued)
                    }
                    .padding(.top, 60)
                }
            }
        }
        .foregroundStyle(Palette.text)
        .background(Palette.base)
        .chromeInset()
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $menuOpen) {
            FolderMenu(name: folder?.name ?? "Folder", rename: { menuOpen = false; renaming = true },
                       delete: { menuOpen = false; confirmDelete() })
                .presentationDetents([.height(220)])
                .presentationDragIndicator(.visible)
                .presentationBackground { SheetGlass() }
                .presentationCornerRadius(Radius.glassSheet)
        }
        .sheet(isPresented: $renaming) {
            NameSheet(kind: .renameFolder(id: id, current: folder?.name ?? "")).environment(app)
        }
    }

    private func confirmDelete() {
        let name = folder?.name ?? "this folder"
        app.confirm = ConfirmRequest(title: "Delete \(name)?", message: "The playlists in it stay in Your Library.", action: "Delete") {
            Task { await FolderActions.delete(id: id, name: name, app: app) { dismiss() } }
        }
    }
}

/// Folder Delete with Undo, shared by the folder page and its tests.
@MainActor enum FolderActions {
    static func delete(id: String, name: String, app: AppModel, then leave: () -> Void) async {
        do {
            let snapshot = try await app.core.deleteFolder(id: id)
            leave()
            await app.library.refresh()
            Haptics.impact(.light)
            app.showToast("Deleted \(name)", action: "Undo") { [app] in
                Task {
                    do {
                        _ = try await app.core.restoreFolder(snapshot)
                        await app.library.refresh()
                    } catch { app.showToast("Couldn't restore \(name)") }
                }
            }
        } catch {
            app.showToast("Couldn't delete \(name)")
        }
    }

    static func rename(id: String, to name: String, app: AppModel) async {
        do {
            try await app.core.renameFolder(id: id, name: name)
            await app.library.refresh()
        } catch {
            app.showToast("Couldn't rename the folder")
        }
    }
}

/// The folder's ··· sheet (Spotify: the folder name, then Rename and Delete).
private struct FolderMenu: View {
    let name: String
    let rename: () -> Void
    let delete: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Icon(name: "folder", size: 28).foregroundStyle(Palette.subdued)
                    .frame(width: 48, height: 48).background(RoundedRectangle(cornerRadius: Radius.xs).fill(Palette.elevatedHighlight))
                Text(name).font(Typo.font(16, .bold)).lineLimit(1)
            }
            .padding(.horizontal, Space.gutter).padding(.top, Space.xl).padding(.bottom, Space.m)
            Divider().overlay(Palette.border)
            row("pencil-simple", "Rename folder", id: "folder-rename", rename)
            row("trash", "Delete folder", id: "folder-delete", delete)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
    }

    private func row(_ icon: String, _ title: String, id: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            HStack(spacing: Space.l) {
                Icon(name: icon, size: 24).foregroundStyle(Palette.subdued)
                Text(title).font(Typo.sheetItem)
                Spacer()
            }
            .padding(.horizontal, Space.gutter).frame(height: 52).contentShape(Rectangle())
        }
        .buttonStyle(SettingsPressStyle())
        .accessibilityIdentifier(id)
    }
}

enum NameSheetKind: Equatable {
    case playlist, folder, collab
    /// Rename an existing folder (the field starts with its name; the button says Save).
    case renameFolder(id: String, current: String)
    var isPlaylist: Bool { self == .playlist || self == .collab }
}

/// Full-height naming screen: centred prompt, a large underlined field, Cancel and an accent Create.
struct NameSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let kind: NameSheetKind
    @State private var name = ""
    @FocusState private var focused: Bool
    @State private var busy = false

    var body: some View {
        VStack(spacing: Space.xl) {
            Spacer()
            Text(prompt)
                .font(Typo.font(24, .bold)).multilineTextAlignment(.center)
            VStack(spacing: 6) {
                TextField("", text: $name)
                    .onChange(of: name) { _, n in if n.count > 100 { name = String(n.prefix(100)) } }
                    .font(Typo.font(34, .bold)).multilineTextAlignment(.center)
                    .focused($focused).submitLabel(.done).onSubmit(create)
                    .tint(Palette.accent)
                    .accessibilityIdentifier("name-field")
                Rectangle().fill(Palette.subdued).frame(height: 1)
            }
            .padding(.horizontal, Space.xxl)
            HStack(spacing: Space.l) {
                Button { dismiss() } label: {
                    Text("Cancel").font(Typo.font(15, .bold)).lineLimit(1).fixedSize().foregroundStyle(Palette.text)
                        .padding(.horizontal, 26).frame(height: 44)
                        .overlay(Capsule().stroke(Palette.dim, lineWidth: 1))
                }
                Button(action: create) {
                    ZStack {
                        Text(isRename ? "Save" : "Create").opacity(busy ? 0 : 1)
                        if busy { ProgressView().controlSize(.small).tint(.black) }
                    }
                    .font(Typo.font(15, .bold)).lineLimit(1).fixedSize().foregroundStyle(.black)
                        .padding(.horizontal, 28).frame(height: 44)
                        .background(Capsule().fill(Palette.accent))
                }
                .disabled(busy)
                .accessibilityIdentifier("name-create")
            }
            .buttonStyle(PressScale())
            Spacer()
            Spacer()
        }
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(hex: "#3a3a3a"), Palette.base], startPoint: .top, endPoint: .center))
        .onAppear {
            switch kind {
            case .playlist, .collab: name = "My playlist #\(app.library.snapshot.playlists.count + 1)"
            case .folder: name = "New folder"
            case .renameFolder(_, let current): name = current
            }
            focused = true
        }
    }

    private var isRename: Bool { if case .renameFolder = kind { true } else { false } }
    private var prompt: String {
        switch kind {
        case .playlist: "Give your playlist a name"
        case .collab: "Name your collaborative playlist"
        case .folder: "Give your folder a name"
        case .renameFolder: "Rename this folder"
        }
    }

    /// The sheet stays open until the item exists: a failure keeps the typed name and says why.
    private func create() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !busy else { return }
        if case .renameFolder(let id, let current) = kind {
            dismiss()
            if n != current { Task { await FolderActions.rename(id: id, to: n, app: app) } }
            return
        }
        busy = true
        Task {
            defer { busy = false }
            let route: Route
            do {
                switch kind {
                case .playlist: route = .playlist(try await app.core.createPlaylist(name: n).id)
                case .collab:
                    let id = try await app.core.createPlaylist(name: n).id
                    route = .playlist(id)
                    // Shared at once, then the invite goes out from the system share sheet.
                    if let link = await app.collab.share(id) { CollabInvite.present(link, name: n, app: app) }
                case .folder, .renameFolder: route = .folder(try await app.core.createFolder(name: n).id)
                }
            } catch {
                app.fail(friendlyError(error, kind.isPlaylist ? "Couldn't create the playlist" : "Couldn't create the folder"))
                return
            }
            dismiss()
            await app.library.refresh()
            app.router.dismissOverlays()
            app.router.tab = .library
            app.router.paths[.library] = [route]
        }
    }
}
