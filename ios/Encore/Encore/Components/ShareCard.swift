// Screenshot share sheet (Spotify: taking a screenshot on Now Playing raises a card of the song with
// colour choices and share targets). The card is rendered to an image and shared with the link.
import SwiftUI
import UIKit

struct ShareCardSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let song: SongItem
    let accent: UIColor?
    @State private var cover: UIImage?
    @State private var style = 0

    private var tint: Color { accent.map { Color(uiColor: $0) } ?? Color(hex: "#2e6f80") }
    private var styles: [AnyShapeStyle] {
        [AnyShapeStyle(tint),
         AnyShapeStyle(LinearGradient(colors: [tint, .black], startPoint: .top, endPoint: .bottom)),
         AnyShapeStyle(Color.black)]
    }
    private var links: ShareLinks { .song(song) }

    var body: some View {
        VStack(spacing: 0) {
            card.padding(.top, Space.xl)
            HStack(spacing: Space.l) {
                ForEach(styles.indices, id: \.self) { i in
                    Button { withAnimation(Motion.quick) { style = i } } label: {
                        Circle().fill(styles[i]).frame(width: 30, height: 30)
                            .overlay(Circle().stroke(style == i ? Palette.text : Palette.dim, lineWidth: 2).padding(-1))
                    }
                    .accessibilityLabel(["Colour", "Gradient", "Black"][i])
                    .accessibilityAddTraits(style == i ? .isSelected : [])
                }
            }
            .padding(.vertical, Space.xl)
            Divider().overlay(Palette.border)
            HStack(alignment: .top, spacing: Space.l) {
                target("link", "Copy link") {
                    UIPasteboard.general.url = links.web ?? links.app
                    dismiss(); app.showToast("Link copied")
                }
                target("download-simple", "Save image") {
                    guard let img = render() else { return }
                    UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                    dismiss(); app.showToast("Saved to Photos")
                }
                target("dots-three", "More") {
                    let items: [Any] = [render() as Any, links.web ?? links.app].compactMap { $0 }
                    dismiss()
                    Task {
                        try? await Task.sleep(nanoseconds: 450_000_000)
                        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
                        guard let top = ShareSheet.topViewController() else { return }
                        vc.popoverPresentationController?.sourceView = top.view
                        top.present(vc, animated: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.gutter).padding(.vertical, Space.l)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Palette.text)
        .task { cover = await ArtworkCache.shared.image(song.thumbnail ?? "") }
    }

    /// The card as shared: the cover, title and artists on a dark panel inside the chosen colour.
    private var card: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Group {
                if let cover { Image(uiImage: cover).resizable().scaledToFill() } else { Palette.elevatedHighlight }
            }
            .frame(width: 196, height: 196).clipShape(RoundedRectangle(cornerRadius: Radius.s))
            Text(song.title).font(Typo.font(18, .bold)).lineLimit(3).padding(.top, Space.s)
            Text(song.artists).font(Typo.font(15)).foregroundStyle(Palette.subdued).lineLimit(2)
            HStack(spacing: 6) {
                Circle().fill(Palette.accent).frame(width: 16, height: 16)
                Text("Spotless").font(Typo.font(13, .bold))
            }
            .padding(.top, Space.s)
        }
        .frame(width: 196, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Radius.l).fill(Color(hex: "#121a1d")))
        .padding(Space.l + 2)
        .background(RoundedRectangle(cornerRadius: Radius.xl).fill(styles[style]))
        .environment(\.colorScheme, .dark)
    }

    @MainActor private func render() -> UIImage? {
        let r = ImageRenderer(content: card.foregroundStyle(Palette.text))
        r.scale = 3
        return r.uiImage
    }

    private func target(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            VStack(spacing: Space.s) {
                Icon(name: icon, size: 24).frame(width: 56, height: 56).background(Circle().fill(Palette.elevatedHighlight))
                Text(label).font(Typo.font(13)).lineLimit(1)
            }
            .frame(width: 72)
        }
        .buttonStyle(PressScale())
    }
}
