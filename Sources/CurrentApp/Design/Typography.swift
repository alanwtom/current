import SwiftUI

/// One type style: size, weight, letter-spacing and line spacing together.
///
/// A bare `Font` isn't enough, because letter-spacing is a separate modifier in
/// SwiftUI and it is doing real work here. Apple's default tracking is tuned for
/// system-sized text on white; a 16pt semibold heading at default tracking looks
/// loose and slightly cheap next to Cursor's chrome, and tightening it by a
/// third of a point is most of the difference. Bundling the two means a heading
/// can't accidentally ship with the size but not the tracking.
struct TypeStyle: Equatable {
    let font: Font
    let tracking: CGFloat
    let lineSpacing: CGFloat

    init(size: CGFloat, weight: Font.Weight, tracking: CGFloat = 0, lineSpacing: CGFloat = 0) {
        self.font = .system(size: size, weight: weight)
        self.tracking = tracking
        self.lineSpacing = lineSpacing
    }
}

/// The app's type scale: **four sizes, three weights.**
///
/// 11 / 13 / 16 / 22, deliberately smaller and tighter than Apple's defaults.
/// The old build used `.headline` / `.callout` / `.caption`, which are sized
/// for iOS reading distances and make a desktop utility look enlarged.
///
/// Four sizes, not seven, and that is the point. This scale used to run
/// 10 / 11 / 12.5 / 13 / 16 / 22 — three of those steps sat inside two points
/// of each other, which is not a hierarchy, it is noise: nobody can see the
/// difference between an 11pt caption and a 12.5pt label, so the difference
/// does no work while still costing a decision every time something is
/// written. 12.5 also wasn't a whole point.
///
/// Where two styles now share a size they are told apart by **weight**, which
/// is legible at any size — `body`, `label` and `heading` are all 13, at
/// regular, medium and semibold. `overline` and `caption` are both 11, and the
/// overline is told apart by being uppercase with wide tracking rather than by
/// a single point of size.
///
/// The working rule, from the same place as the grid: **no more than three
/// sizes and three weights in one component.** Four sizes across the whole app
/// makes that easy to hold to.
///
/// The rule about tracking: **negative above 14pt, positive below 11pt.** Large
/// text needs pulling together, small text needs opening up. In the middle,
/// leave it alone.
enum Typo {

    /// Once per surface at most — an empty state's headline, the palette's field.
    static let display = TypeStyle(size: 22, weight: .semibold, tracking: -0.45)

    /// Sheet and settings-pane titles.
    static let title = TypeStyle(size: 16, weight: .semibold, tracking: -0.25)

    /// Card headers, inspector section titles, a torrent's name.
    static let heading = TypeStyle(size: 13, weight: .semibold, tracking: -0.1)

    /// Default running text: settings explanations, inspector values.
    static let body = TypeStyle(size: 13, weight: .regular, lineSpacing: 2)

    /// Interactive text — buttons, sidebar rows, menu items. Medium rather than
    /// regular so a control reads as a control without needing a border.
    static let label = TypeStyle(size: 13, weight: .medium)

    /// Secondary detail lines, stat labels, keyboard hints.
    static let caption = TypeStyle(size: 11, weight: .medium, tracking: 0.1)

    /// Uppercased section headers in the sidebar and settings. Same size as
    /// `caption`: the caps and the wide tracking already say "this is a header",
    /// so it does not also need to be a point smaller. The tracking is what
    /// stops all-caps at this size from reading as a solid block.
    static let overline = TypeStyle(size: 11, weight: .semibold, tracking: 0.65)

    /// Monospaced, for a technical error message or a magnet URI.
    static let mono = TypeStyle(size: 11, weight: .regular)
}

extension View {
    /// Applies a type style — font, tracking and line spacing in one go.
    func typeStyle(_ style: TypeStyle) -> some View {
        self.font(style.font)
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }

    /// Continuously-updating numbers (rates, sizes, ETAs) must never shift
    /// width, or the whole row twitches once a second.
    func tabularNumerics() -> some View {
        monospacedDigit()
    }

    /// A number that should count rather than cut when it changes. Used on
    /// rates and totals so a value sliding from 1.2 to 1.3 MB/s reads as the
    /// same number moving, not as two different numbers swapped.
    func numericTransition() -> some View {
        contentTransition(.numericText())
    }
}

extension Font {
    func tabularNumerics() -> Font {
        monospacedDigit()
    }

    /// The monospaced style as a plain `Font`, for the places that take one
    /// directly (a `TextField`'s font, say).
    static var monoStyle: Font {
        .system(size: 11, weight: .regular, design: .monospaced)
    }
}
