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

/// The app's type scale.
///
/// Seven steps, deliberately smaller and tighter than Apple's defaults. The old
/// build used `.headline` / `.callout` / `.caption`, which are sized for iOS
/// reading distances and make a desktop utility look enlarged. Everything here
/// lands between 10 and 22pt, and the jumps are big enough that two adjacent
/// steps never look like a mistake.
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
    static let body = TypeStyle(size: 12.5, weight: .regular, lineSpacing: 2)

    /// Interactive text — buttons, sidebar rows, menu items. Medium rather than
    /// regular so a control reads as a control without needing a border.
    static let label = TypeStyle(size: 12.5, weight: .medium)

    /// Secondary detail lines, stat labels, keyboard hints.
    static let caption = TypeStyle(size: 11, weight: .medium, tracking: 0.1)

    /// Uppercased section headers in the sidebar and settings. The wide tracking
    /// is what stops all-caps at this size from reading as a solid block.
    static let overline = TypeStyle(size: 10, weight: .semibold, tracking: 0.65)

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
