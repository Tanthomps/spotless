// Cover loading, caching and the artwork colour (port of the desktop's `artcolor.ts` pickAccent:
// 32x32, 3-bit buckets, chroma-weighted winner). Spotify tints the mini player, Now Playing and
// entity headers from that colour, darkened.
import SwiftUI
import UIKit

actor ArtworkCache {
    static let shared = ArtworkCache()
    private let images = NSCache<NSString, UIImage>()
    private var accents: [String: UIColor?] = [:]
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
        c.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: c)
    }()

    /// Snapshot tests: deterministic covers drawn from the URL instead of the network.
    nonisolated(unsafe) static var stubbed = false

    func image(_ url: String) async -> UIImage? {
        if Self.stubbed && !url.hasPrefix("mfy:") {
            let key = "stub:" + url as NSString
            if let hit = images.object(forKey: key) { return hit }
            let img = await MainActor.run { StubArt.render(url) }
            images.setObject(img, forKey: key)
            return img
        }
        if let hit = images.object(forKey: url as NSString) { return hit }
        if url.hasPrefix("mfy:") {
            let img = await MainActor.run { MfyCoverArt.render(url) }
            if let img { images.setObject(img, forKey: url as NSString) }
            return img
        }

        if let t = inflight[url] { return await t.value }
        let session = self.session
        let t = Task<UIImage?, Never> {
            // A picked playlist cover is a local file path (`set_playlist_cover`, stream ios-p2).
            guard let u = url.hasPrefix("/") ? URL(fileURLWithPath: url) : URL(string: url),
                  let (data, _) = try? await session.data(from: u) else { return nil }
            return UIImage(data: data)?.preparingForDisplay()
        }
        inflight[url] = t
        let img = await t.value
        inflight[url] = nil
        if let img { images.setObject(img, forKey: url as NSString) }
        return img
    }

    /// Looks up art for an item that came without any (imported history, local mixes). Set by the app.
    nonisolated(unsafe) static var resolver: ((ArtRef) async -> String?)?
    private var resolved: [ArtRef: String?] = [:]
    func resolve(_ r: ArtRef) async -> String? {
        if let hit = resolved[r] { return hit }
        let got = await Self.resolver?(r)
        resolved[r] = got
        return got
    }

    func cached(_ url: String) -> UIImage? { images.object(forKey: (Self.stubbed && !url.hasPrefix("mfy:") ? "stub:" + url : url) as NSString) }

    /// The cover's raw accent colour, or nil for a greyscale cover.
    func accent(_ url: String) async -> UIColor? {
        if let hit = accents[url] { return hit }
        guard let img = await image(url) else { return nil }
        let c = Self.pickAccent(img)
        accents[url] = c
        return c
    }

    static func pickAccent(_ image: UIImage) -> UIColor? {
        let size = 32
        guard let cg = image.cgImage else { return nil }
        var px = [UInt8](repeating: 0, count: size * size * 4)
        guard let ctx = CGContext(data: &px, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
        struct B { var n = 0.0, r = 0.0, g = 0.0, b = 0.0, score = 0.0 }
        var buckets: [Int: B] = [:]
        var total = 0, colourful = 0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] >= 128 {
            total += 1
            let r = Double(px[i]), g = Double(px[i + 1]), b = Double(px[i + 2])
            let mx = max(r, g, b) / 255, mn = min(r, g, b) / 255, chroma = mx - mn
            if mx < 0.08 || chroma < 0.05 { continue }
            colourful += 1
            let key = (Int(px[i]) >> 5) << 6 | (Int(px[i + 1]) >> 5) << 3 | (Int(px[i + 2]) >> 5)
            var cur = buckets[key] ?? B()
            cur.n += 1; cur.r += r; cur.g += g; cur.b += b; cur.score += chroma * (1 - abs(mx - 0.45))
            buckets[key] = cur
        }
        guard total > 0, Double(colourful) >= Double(total) * 0.02,
              let best = buckets.values.max(by: { $0.score < $1.score }) else { return Self.average(px) }
        let c = UIColor(red: best.r / best.n / 255, green: best.g / best.n / 255, blue: best.b / best.n / 255, alpha: 1)
        var s: CGFloat = 0
        c.getHue(nil, saturation: &s, brightness: nil, alpha: nil)
        return s < 0.15 ? Self.average(px) : c
    }

    /// Mostly-grey cover: its average colour with a little saturation kept, so surfaces still follow
    /// the artwork (Spotify tints white/grey covers a muted blue-grey or brown, never flat grey).
    static func average(_ px: [UInt8]) -> UIColor? {
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] >= 128 {
            r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]); n += 1
        }
        guard n > 0 else { return nil }
        let c = UIColor(red: r / n / 255, green: g / n / 255, blue: b / n / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        return UIColor(hue: h, saturation: max(s, 0.18), brightness: max(v, 0.5), alpha: 1)
    }
}

extension UIColor {
    /// The accent at a fixed HSV value/saturation band: how Spotify darkens artwork colour for surfaces.
    func surface(value: CGFloat, maxSaturation: CGFloat = 0.75) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0
        getHue(&h, saturation: &s, brightness: &v, alpha: nil)
        return Color(hue: h, saturation: min(s, maxSaturation), brightness: min(v, value))
    }
}

/// YouTube artwork URLs carry their size (`=w544-h544` or `=s576`); ask for what the view needs
/// (the desktop's `thumb`).
func sizedArt(_ url: String?, _ px: Int) -> String? {
    guard let url else { return nil }
    if let r = url.range(of: #"=w\d+-h\d+"#, options: .regularExpression) {
        return url.replacingCharacters(in: r, with: "=w\(px)-h\(px)")
    }
    if let r = url.range(of: #"=s\d+"#, options: .regularExpression) {
        return url.replacingCharacters(in: r, with: "=s\(px)")
    }
    return url
}

/// Square (or circular) cover with a placeholder; loads through `ArtworkCache`.
/// What a cover belongs to, so a missing or broken thumbnail can be looked up (`ArtworkCache.resolve`).
struct ArtRef: Hashable, Sendable {
    let id: String
    let title: String
}

struct ArtImage: View {
    let url: String?
    var px: Int = 544
    var radius: CGFloat = Radius.s
    var circle = false
    var placeholderIcon = "ph-music-note"
    /// No thumbnail (or one that won't load): look the item's own art up instead of a note icon.
    var fallback: ArtRef? = nil
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(Color(hex: "#282828")).overlay {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(Color(hex: "#282828"))
                    .overlay(Image(placeholderIcon).renderingMode(.template).resizable().scaledToFit()
                        .foregroundStyle(Palette.subdued).padding(10).frame(maxWidth: 48, maxHeight: 48))
            }
        }
        .clipped()
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
        .task(id: "\(url ?? "")#\(fallback?.id ?? "")") {
            if let u = sizedArt(url, px) {
                if let hit = await ArtworkCache.shared.cached(u) { image = hit; return }
                if let img = await ArtworkCache.shared.image(u) {
                    withAnimation(.easeOut(duration: 0.15)) { image = img }
                    return
                }
            }
            guard let fallback, let found = await ArtworkCache.shared.resolve(fallback),
                  let img = await ArtworkCache.shared.image(found.hasPrefix("mfy:") ? found : sizedArt(found, px) ?? found) else { image = nil; return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.15)) { image = img }
        }
    }
}

/// Async artwork accent for a URL, as a SwiftUI value.
struct ArtAccent: ViewModifier {
    let url: String?
    @Binding var color: UIColor?
    func body(content: Content) -> some View {
        content.task(id: url) {
            guard let u = sizedArt(url, 120) else { color = nil; return }
            let c = await ArtworkCache.shared.accent(u)
            withAnimation(.easeInOut(duration: 0.6)) { color = c }
        }
    }
}

extension View {
    func artAccent(_ url: String?, into color: Binding<UIColor?>) -> some View { modifier(ArtAccent(url: url, color: color)) }
}
