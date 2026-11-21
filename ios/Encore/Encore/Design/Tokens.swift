// Design tokens: the desktop palette (`docs/spotify-spec/tokens.json`) in Swift, plus iOS sizes in
// points from `docs/spotify-spec/ios/` (estimates from public references until re-measured on the
// owner's screenshots, plan §4.2).
import SwiftUI

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xff) / 255; g = Double((v >> 16) & 0xff) / 255
            b = Double((v >> 8) & 0xff) / 255; a = Double(v & 0xff) / 255
        } else {
            r = Double((v >> 16) & 0xff) / 255; g = Double((v >> 8) & 0xff) / 255; b = Double(v & 0xff) / 255; a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum Palette {
    // surfaces
    static let app = Color(hex: "#000000")
    static let base = Color(hex: "#121212")
    static let highlight = Color(hex: "#1f1f1f")
    static let elevated = Color(hex: "#1f1f1f")
    static let elevatedHighlight = Color(hex: "#2a2a2a")
    static let menu = Color(hex: "#282828")
    static let sheet = Color(hex: "#282828")
    static let tinted = Color.white.opacity(0.10)
    static let tintedHighlight = Color.white.opacity(0.14)
    static let tintedPress = Color.white.opacity(0.21)
    // text
    static let text = Color.white
    static let subdued = Color(hex: "#b3b3b3")
    static let meta = Color(hex: "#cdcdcd")
    static let muted = Color.white.opacity(0.7)
    static let dim = Color(hex: "#7c7c7c")
    // accent: Spotify green (#1ED760, the current brand green) is the ONE accent; nothing else
    // hard-codes it. Hover = 12% toward white, press = 12% toward black. Black sits on it (~11:1).
    // As words on dark surfaces it reads ~10:1 on #121212 and stays above 7:1 on #282828.
    static let accent = Color(hex: "#1ed760")
    static let accentHover = Color(hex: "#39dc73")
    static let accentPress = Color(hex: "#1abd54")
    static let accentText = Color(hex: "#1ed760")
    /// Deep brand tile behind an accent glyph (Your Episodes).
    static let accentTile = Color(hex: "#0b5a2a")
    static let accentTileDeep = Color(hex: "#063318")
    /// Semantic "went up" (chart trends): deliberately not the brand, so it can't be confused with
    /// the red "down" arrow.
    static let positive = Color(hex: "#34d399")
    static let announcement = Color(hex: "#539df5")
    static let negative = Color(hex: "#f3727f")
    // progress
    static let progressTrack = Color.white.opacity(0.3)
    static let border = Color.white.opacity(0.10)
    static let likedCover = LinearGradient(colors: [Color(hex: "#450af5"), Color(hex: "#c4efd9")],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let likedHeader = Color(red: 80 / 255, green: 56 / 255, blue: 160 / 255)
}

/// Figtree (OFL) stands in for Spotify Mix; static instances bundled from the desktop's fontsource files.
enum Typo {
    enum Weight: String { case regular = "Regular", medium = "Medium", semibold = "SemiBold", bold = "Bold", extraBold = "ExtraBold", black = "Black" }
    /// Follows the iPhone's text size (relative to body); the app root caps it at `maxTextSize` so the
    /// fixed-height rows, mini player and tab bar still hold their text.
    static func font(_ size: CGFloat, _ w: Weight = .regular) -> Font { .custom("Figtree-\(w.rawValue)", size: size, relativeTo: .body) }
    static let maxTextSize: DynamicTypeSize = .xLarge

    // roles (pt), iOS scale: tokens-ios.json
    static let largeTitle = font(24, .bold)        // "Search", "Your Library" header
    static let pageTitle = font(24, .bold)         // entity title under the cover
    static let sectionTitle = font(24, .bold)      // shelf titles
    static let rowTitle = font(16, .regular)
    static let rowTitleMedium = font(16, .medium)
    static let rowSubtitle = font(14, .regular)
    static let cardTitle = font(14, .bold)
    static let cardSubtitle = font(14, .regular)
    static let shortcut = font(14, .bold)
    static let chip = font(14, .medium)
    static let tabLabel = font(10, .medium)
    static let miniTitle = font(14, .bold)
    static let miniArtist = font(14, .regular)
    static let npTitle = font(26, .bold)   // Spotify: 18.6 pt cap height
    static let npArtist = font(17, .regular)
    static let time = font(11, .regular)
    static let meta = font(13, .regular)
    static let metaBold = font(13, .bold)
    static let button = font(14, .bold)
    static let sheetItem = font(16, .regular)
    static let lyricsCard = font(22, .bold)
    static let lyricsFull = font(26, .bold)
}

/// A count with its noun, right at 1 and grouped for big numbers ("1 song", "12,480 songs").
func counted(_ n: Int, _ one: String, _ many: String? = nil) -> String {
    "\(n.formatted()) \(n == 1 ? one : many ?? one + "s")"
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Screen side gutter.
    static let gutter: CGFloat = 16
}

enum Radius {
    static let xs: CGFloat = 2
    static let s: CGFloat = 4
    static let m: CGFloat = 6
    static let l: CGFloat = 8
    static let xl: CGFloat = 12
    static let sheet: CGFloat = 12
    /// Floating glass sheets (Create, `…`, queue): concentric with the display corners.
    static let glassSheet: CGFloat = 36
}

enum Metrics {
    static let tabBarHeight: CGFloat = 50           // above the home-indicator inset
    static let tabIcon: CGFloat = 24
    static let miniPlayerHeight: CGFloat = 56
    static let miniPlayerInset: CGFloat = 8
    static let miniCover: CGFloat = 40
    static let miniGap: CGFloat = 2                // gap between mini player and tab bar
    static let rowHeight: CGFloat = 64             // track row with 48pt art
    static let rowArt: CGFloat = 48
    static let libraryRowArt: CGFloat = 64
    static let chipHeight: CGFloat = 32
    static let shortcutHeight: CGFloat = 56
    static let card: CGFloat = 160
    static let cardSmall: CGFloat = 128
    static let playButton: CGFloat = 48
    static let npPlayButton: CGFloat = 64
    static let searchField: CGFloat = 48
}

/// Animations. With Reduce Motion on, springs become short fades and slides become cross-fades
/// (Apple HIG; Spotify follows the system setting for its sheet and player transitions).
enum Motion {
    static var reduce: Bool { UIAccessibility.isReduceMotionEnabled }
    static var spring: Animation { reduce ? .easeInOut(duration: 0.18) : .spring(response: 0.35, dampingFraction: 0.86) }
    static var quick: Animation { reduce ? .linear(duration: 0.12) : .easeOut(duration: 0.2) }
    /// Leaving is quicker than arriving: the same feel as `spring` at 0.8x the time.
    static var exit: Animation { reduce ? .easeOut(duration: 0.14) : .spring(response: 0.28, dampingFraction: 0.86) }
    /// Confirmations only (toasts, success): a ~4% settle on landing. Never menus, sheets or buttons.
    static var land: Animation { reduce ? .easeOut(duration: 0.18) : .spring(response: 0.4, dampingFraction: 0.74) }
    /// List rows cascade in 30 ms apart, capped at 10 rows.
    static func rowDelay(_ i: Int) -> Double { reduce ? 0 : Double(min(i, 10)) * 0.03 }
    /// Screen blocks (header, hero, shelves) arrive 70 ms apart, capped at 8.
    static func blockDelay(_ i: Int) -> Double { reduce ? 0 : Double(min(i, 8)) * 0.07 }
    /// Pills and small popovers: grow from 0.95 with a short blur, never from nothing.
    static var pop: AnyTransition {
        if reduce { return .opacity }
        return .modifier(active: PopEffect(scale: 0.95, blur: 6, opacity: 0), identity: PopEffect(scale: 1, blur: 0, opacity: 1))
    }
    /// Revealed content wipes in top to bottom behind a mask instead of fading.
    static var reveal: AnyTransition {
        if reduce { return .opacity }
        return .modifier(active: RevealEffect(progress: 0), identity: RevealEffect(progress: 1))
    }
    /// A confirmation arriving from the bottom: travel plus a motion blur that eases to 0 at rest.
    static var toast: AnyTransition {
        if reduce { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .bottom).combined(with: .modifier(active: PopEffect(scale: 1, blur: 8, opacity: 0), identity: PopEffect(scale: 1, blur: 0, opacity: 1))),
            removal: .move(edge: .bottom).combined(with: .opacity))
    }
    /// A slide in from `edge`, or a fade with Reduce Motion.
    static func slide(_ edge: Edge, fade: Bool = false) -> AnyTransition {
        if reduce { return .opacity }
        return fade ? .move(edge: edge).combined(with: .opacity) : .move(edge: edge)
    }
}

/// Scale + gaussian blur + opacity in one modifier, so transitions can animate all three together.
struct PopEffect: ViewModifier {
    let scale: CGFloat
    let blur: CGFloat
    let opacity: Double
    func body(content: Content) -> some View {
        content.scaleEffect(scale).blur(radius: blur).opacity(opacity)
    }
}

struct RevealEffect: ViewModifier, Animatable {
    var progress: CGFloat
    var animatableData: CGFloat { get { progress } set { progress = newValue } }
    func body(content: Content) -> some View {
        content.mask(alignment: .top) {
            GeometryReader { g in Rectangle().frame(height: g.size.height * progress) }
        }
    }
}

/// One "done" beat: 1 → 1.04 → 1 each time `trigger` changes. Off with Reduce Motion.
struct Pulse<T: Equatable>: ViewModifier {
    let trigger: T
    func body(content: Content) -> some View {
        if Motion.reduce {
            content
        } else {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { v, s in v.scaleEffect(s) } keyframes: { _ in
                CubicKeyframe(1.04, duration: 0.12)
                CubicKeyframe(1.0, duration: 0.16)
            }
        }
    }
}

/// Rows cascade and screen blocks arrive one by one: fade + 8 pt rise + a little blur, once per view
/// identity (a recycled row that scrolls back in does not re-animate).
struct Arrive: ViewModifier {
    let delay: Double
    @State private var shown: Bool
    init(delay: Double, animates: Bool) { self.delay = delay; _shown = State(initialValue: !animates) }
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || Motion.reduce ? 0 : 8)
            .blur(radius: shown || Motion.reduce ? 0 : 3)
            .onAppear {
                guard !shown else { return }
                withAnimation(Motion.reduce ? .easeOut(duration: 0.12) : .easeOut(duration: 0.28).delay(delay)) { shown = true }
            }
    }
}

extension View {
    func pulse<T: Equatable>(on trigger: T) -> some View { modifier(Pulse(trigger: trigger)) }
    /// Row `i` of a list arriving (30 ms stagger).
    // ponytail: rows past the first screenful never animate; a lazy list that drops a top row's state
    // can re-fade it on scroll-up. A per-screen "first load" flag if that shows.
    func arriveRow(_ i: Int) -> some View { modifier(Arrive(delay: Motion.rowDelay(i), animates: i < 12)) }
    /// Block `i` of a screen arriving (70 ms stagger).
    func arriveBlock(_ i: Int) -> some View { modifier(Arrive(delay: Motion.blockDelay(i), animates: i < 8)) }
}
