import SwiftUI
import AppKit

/// Every colour in the app.
///
/// Nothing here comes from the system. macOS ships a perfectly good palette —
/// `windowBackgroundColor`, `controlAccentColor`, `.secondary` — and using it is
/// exactly why the old build looked like a stock Mac utility. The whole point of
/// this file is that Current picks its own greys, its own one accent, and its own
/// contrast steps, so it reads as itself in both light and dark.
///
/// **Two values per token, always.** Each colour is a dynamic `NSColor` that
/// resolves against whatever appearance the window is wearing, so views never
/// branch on light-versus-dark themselves. `AppearanceController` sets that
/// appearance app-wide; see `Appearance.swift`.
///
/// One catch worth knowing about, because it has already cost a debugging
/// session in `LaunchIntro`: a dynamic colour handed straight to a `Canvas`
/// draws as fully transparent. Inside a `Canvas`, resolve first —
/// `Color(token.resolve(in: environment))`.
enum Theme {

    // MARK: - Surfaces
    //
    // Four steps, and four is the limit. Cursor's window is essentially two
    // flat planes with a couple of barely-there lifts on top, and that
    // restraint is most of why it looks calm. Every extra elevation step is
    // another edge competing for attention.

    /// The window's outer shell: title bar, sidebar, inspector. Recessed —
    /// slightly darker than the canvas in dark mode, slightly greyer in light.
    static let chrome = dynamic(light: rgb(244, 244, 246), dark: rgb(18, 18, 20))

    /// The content plane the library sits on. The brightest large area.
    static let canvas = dynamic(light: rgb(255, 255, 255), dark: rgb(24, 24, 27))

    /// Lifted off the canvas: cards, popovers, the command palette, toasts.
    static let raised = dynamic(light: rgb(255, 255, 255), dark: rgb(32, 32, 36))

    /// Floating above everything — menus and the palette's own rows.
    static let overlay = dynamic(light: rgb(252, 252, 253), dark: rgb(40, 40, 45))

    /// Dimming behind a modal surface. Deliberately gentle; a heavy scrim makes
    /// a palette feel like a page change rather than a keystroke.
    static let scrim = dynamic(light: rgba(0, 0, 0, 0.14), dark: rgba(0, 0, 0, 0.42))

    // MARK: - The one translucent layer
    //
    // Only the library list is glass. The chrome bar, the sidebar and the
    // inspector are solid, and so is everything floating above them.
    //
    // Glass everywhere was the first attempt and it was too much: a window whose
    // every panel shows the desktop has no structure left, and small text over
    // somebody's wallpaper is tiring to read. Restricting it to the content
    // plane keeps the frame of the app solid and gives the one surface you
    // actually look *into* a sense of depth.
    //
    // The alpha is deliberately high. Two settings multiply here — this and the
    // blur material behind it — and getting that wrong in either direction has
    // already cost two builds: `.underWindowBackground` with a 0.7 tint was
    // invisible, and `.hudWindow` with a 0.35 tint made the list unreadable.
    // This is a hint of depth, not a view of the desktop.

    static let canvasVeil = dynamic(light: rgba(255, 255, 255, 0.93), dark: rgba(24, 24, 27, 0.92))

    // MARK: - Fills
    //
    // The interaction ladder. Hover, then selected, then pressed — each one a
    // single step up, all of them neutral. A selected row that turns blue is
    // the loudest thing on screen for no reason; the accent is worth more when
    // it is spent on one thing.

    /// Hover. Just enough that the cursor feels like it landed on something.
    static let fillSubtle = dynamic(light: rgba(0, 0, 0, 0.035), dark: rgba(255, 255, 255, 0.04))

    /// Selected, at rest.
    static let fillMuted = dynamic(light: rgba(0, 0, 0, 0.06), dark: rgba(255, 255, 255, 0.07))

    /// Selected and hovered, or a pressed control.
    static let fillStrong = dynamic(light: rgba(0, 0, 0, 0.09), dark: rgba(255, 255, 255, 0.11))

    /// Inset wells: the search field, a segmented control's track. Recessed —
    /// darker than the surface it sits in, which is what makes a field read as
    /// something you type *into*.
    static let well = dynamic(light: rgba(0, 0, 0, 0.05), dark: rgba(0, 0, 0, 0.24))

    /// A progress bar's empty half.
    ///
    /// Deliberately *not* `well`. A recessed dark groove works for a 28pt-tall
    /// field with a border to define it, but at 3pt tall on a near-black canvas
    /// it vanishes completely — the first build of this had bars whose unfilled
    /// portion was invisible, so a 4%-complete download looked like a stray blue
    /// dash floating in the row. A light track reads as a container at any
    /// thickness.
    static let track = dynamic(light: rgba(0, 0, 0, 0.09), dark: rgba(255, 255, 255, 0.10))

    // MARK: - Strokes

    /// Hairlines and control borders. Low enough to read as an edge rather than
    /// as a line someone drew.
    static let stroke = dynamic(light: rgba(0, 0, 0, 0.09), dark: rgba(255, 255, 255, 0.08))

    /// Borders that need to hold their own — a focused field, a card edge on
    /// top of another card.
    static let strokeStrong = dynamic(light: rgba(0, 0, 0, 0.16), dark: rgba(255, 255, 255, 0.15))

    /// The single-pixel highlight along the top of a raised surface. This is the
    /// cheapest trick in dark UI: one 8%-white line and a flat rectangle starts
    /// to look like a physical object.
    static let strokeHighlight = dynamic(light: rgba(255, 255, 255, 0.9), dark: rgba(255, 255, 255, 0.07))

    // MARK: - Text
    //
    // A four-step ramp, and never pure white on dark — #FFFFFF on a near-black
    // background buzzes. Stopping at 93% keeps long names comfortable to read.

    static let text = dynamic(light: rgb(24, 24, 27), dark: rgb(237, 237, 240))
    static let textSecondary = dynamic(light: rgb(90, 90, 100), dark: rgb(161, 161, 170))
    static let textTertiary = dynamic(light: rgb(138, 138, 148), dark: rgb(113, 113, 122))
    /// Placeholders, disabled labels, decorative glyphs in empty states.
    static let textQuaternary = dynamic(light: rgb(176, 176, 185), dark: rgb(82, 82, 91))

    // MARK: - Colour policy
    //
    // **Colour carries state and outcome. It never decorates, and it never says
    // the same thing twice.**
    //
    //   accent  — this is happening, or this is on: an active download, a
    //             switch that's engaged, the focus ring, a drop target, the one
    //             primary action on a surface.
    //   seeding — giving back.
    //   complete— it worked.
    //   warning — something you can still act on: a rare swarm, a budget about
    //             to run out.
    //   failure — it broke, or this control destroys something.
    //
    // Two rules keep that from turning into a rainbow, and both came out of
    // getting it wrong in opposite directions:
    //
    // 1. **Never colour a number.** The first pass painted every download rate
    //    accent blue. Six downloads meant six loud blue numbers, and a real
    //    failure had nowhere to stand out. Rates, sizes and counts are data;
    //    they are always the grey ramp.
    // 2. **At most two coloured elements per row, and they must agree.** A row
    //    says its state with a tinted glyph and a tinted progress bar — the same
    //    state, twice, quietly. It used to also carry a filled tinted circle, a
    //    coloured rate and a coloured glow, which is four voices for one fact.
    //
    // The correction to all that briefly went too far the other way — everything
    // neutral, states told apart only by a word — and a torrent monitor whose
    // whole job is showing you state at a glance shouldn't need to be read.
    // This is the middle: coloured where it identifies something, grey
    // everywhere else.

    static let accent = dynamic(light: rgb(20, 122, 232), dark: rgb(63, 169, 255))
    /// A tinted wash for accent-flavoured backgrounds — drop targets, a
    /// selected option.
    static let accentSoft = dynamic(light: rgba(20, 122, 232, 0.10), dark: rgba(63, 169, 255, 0.14))
    /// The focus ring.
    static let accentRing = dynamic(light: rgba(20, 122, 232, 0.35), dark: rgba(63, 169, 255, 0.40))
    /// On top of an accent fill.
    static let textOnAccent = Color.white

    // MARK: - Transfer states

    /// Active download — the accent, so "this is moving" and "this is on" are
    /// the same colour throughout the app.
    static var downloading: Color { accent }
    static let seeding = dynamic(light: rgb(13, 148, 136), dark: rgb(45, 212, 191))
    static let complete = dynamic(light: rgb(22, 163, 74), dark: rgb(74, 222, 128))
    static let warning = dynamic(light: rgb(180, 111, 8), dark: rgb(251, 191, 36))
    static let failure = dynamic(light: rgb(206, 43, 43), dark: rgb(248, 113, 113))

    /// Paused, queued, resolving — a bar that is present but not doing
    /// anything. Grey rather than a fifth hue: "stopped" is the absence of a
    /// state, not another one.
    static let progressIdle = dynamic(light: rgba(0, 0, 0, 0.26), dark: rgba(255, 255, 255, 0.32))

    // MARK: - Inverted controls
    //
    // For a control that needs to be the strongest thing on a surface without
    // being a fifth colour — currently just the drag handle between columns.

    static let inverse = dynamic(light: rgb(24, 24, 27), dark: rgb(237, 237, 240))
    static let onInverse = dynamic(light: rgb(250, 250, 252), dark: rgb(20, 20, 23))

    // MARK: - Shadows
    //
    // Two shadows, because macOS dark mode barely renders them and light mode
    // needs them. Both are soft and offset downward only — no ambient spread
    // that would fog the surface underneath.

    static let shadow = dynamic(light: rgba(0, 0, 0, 0.13), dark: rgba(0, 0, 0, 0.45))
    static let shadowDeep = dynamic(light: rgba(0, 0, 0, 0.22), dark: rgba(0, 0, 0, 0.60))
}

// MARK: - Dynamic colour plumbing

/// A colour that resolves itself per appearance.
///
/// `NSColor(name:dynamicProvider:)` rather than two `Color`s and a branch on
/// `@Environment(\.colorScheme)`: this way a token works in AppKit code (window
/// backgrounds, the status item) and SwiftUI alike, and a view never has to know
/// which mode it is in.
private func dynamic(light: NSColor, dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func rgb(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    rgba(r, g, b, 1)
}

private func rgba(_ r: Int, _ g: Int, _ b: Int, _ alpha: Double) -> NSColor {
    NSColor(srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: alpha)
}

// MARK: - AppKit access

extension Theme {
    /// For the handful of places that need a real `NSColor` — window background,
    /// the notch panel, the status item.
    static func nsColor(_ color: Color) -> NSColor { NSColor(color) }
}
