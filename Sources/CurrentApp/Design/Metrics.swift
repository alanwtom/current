import SwiftUI

/// The spacing scale, on an 8pt base grid.
///
/// **8 is the base unit; 4 is the only subdivision.** Layout spacing — gaps
/// between things, padding inside surfaces — is a multiple of 8. Component
/// *sizing* (see `Size`) is allowed the 4pt half-step, because a 28pt control
/// is a real height and a 32pt one is a chunky one; that split is how 8pt
/// systems are actually used rather than a compromise.
///
/// Six values, and the constraint is the feature: hand-typed padding is how an
/// interface ends up with 11pt here and 13pt there, which nobody can name but
/// everybody can feel. If a layout seems to need a value that isn't here, the
/// layout is usually wrong.
///
/// This scale used to carry a `hair` of 2 and an `s` of 6, and neither sat on
/// any grid. They were the two most-used values in the app after `m`, so the
/// app was, in practice, off-grid nearly everywhere: 41 gaps at 6pt and four at
/// 2pt. They are folded into 4 and 8 now.
enum Space {
    /// The half-step. Icon-to-label inside a tight pill, a badge's inset.
    static let xs: CGFloat = 4
    /// **The base unit.** The default gap between related controls.
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    /// Between groups.
    static let xl: CGFloat = 16
    /// Surface padding — a card's inside edge, a pane's margin.
    static let xxl: CGFloat = 24
    /// Between unrelated sections.
    static let xxxl: CGFloat = 32
}

/// Corner radii.
///
/// All of these get `style: .continuous`. A circular corner next to a squircle
/// is the single most obvious tell that a control was drawn by hand rather than
/// designed, and macOS's own controls are all continuous.
///
/// The nesting rule: an inner radius should be the outer radius minus the gap
/// between them. A 12pt card with 8pt padding wants 4pt corners inside it, or
/// the two curves fight.
enum Radius {
    /// Progress tracks, tiny badges.
    static let xs: CGFloat = 4
    /// Chips, list-row hover fills, menu items.
    static let s: CGFloat = 6
    /// Buttons, fields, sidebar rows.
    static let m: CGFloat = 8
    /// Cards, popovers, inspector panels.
    static let l: CGFloat = 12
    /// The command palette, sheets — the biggest surfaces.
    static let xl: CGFloat = 16
    /// The window itself, matched to macOS's own window corner.
    static let window: CGFloat = 10
}

/// Control sizes.
///
/// Fixed heights, because a control that sizes to its content changes height
/// when its label changes — and in this app a control whose height changes on
/// an engine tick can take the whole window down with it. See the layout-churn
/// section of AGENTS.md.
/// Control sizes, on the grid's 4pt half-step.
///
/// Sizing gets the half-step where spacing does not, and that split is how 8pt
/// systems are actually used: a 28pt control is a real height and a 32pt one is
/// a chunky one, so forcing every control onto multiples of 8 would coarsen the
/// app rather than order it. Layout — the gaps *between* these things — stays
/// on 8.
///
/// Three values here are deliberate exceptions and each has a reason that
/// outranks the grid. They are called out where they are defined.
enum Size {
    /// Inline chips and the smallest icon buttons.
    static let controlS: CGFloat = 24
    /// The default: buttons, fields, menu triggers.
    static let controlM: CGFloat = 28
    /// Primary actions and the search field.
    static let controlL: CGFloat = 32

    /// Square icon buttons in the chrome bar. Matches `controlM` so an icon
    /// button and a text button in the same row are the same height.
    static let iconButton: CGFloat = 28
    /// Glyphs inside those buttons.
    static let icon: CGFloat = 13
    /// Sidebar and menu row glyphs.
    static let iconSmall: CGFloat = 12

    /// **Off the grid on purpose.** The fixed column a row's glyph sits in —
    /// sidebar rows, settings rail rows, palette rows. Every label in a list starts at the far side of it,
    /// which is the only reason a column of mixed symbols reads as a column.
    ///
    /// **18 because that is measured, not chosen.** SF Symbols are not square
    /// and not even close: at `iconSmall` the app's row glyphs run from 14pt
    /// wide (`bell`) to 18 (`internaldrive`, `arrow.up.arrow.down`). This column
    /// used to be 16 — and SwiftUI frames don't clip, so anything wider spilled
    /// out both sides. `battery.75` in the settings rail was 21pt wide and hung
    /// 2.5pt past the icons above and below it while crowding its own label; it
    /// has since been swapped for a glyph that fits (`bolt.batteryblock`, 17).
    ///
    /// If you add a symbol to a row list, measure it. Anything over 18 either
    /// gets replaced or this number goes up — and it can't go up silently,
    /// because every label in the app moves with it.
    static let iconColumn: CGFloat = 18

    /// A library row at its normal height. Fixed on purpose — rows carry live
    /// numbers, and a row that grows by a point when an ETA appears makes the
    /// list re-measure every second.
    ///
    /// **Off the grid on purpose,** and the second of the three exceptions. 56
    /// is the grid's answer and it does fit, but a row holds two lines of type
    /// and a 4pt meter, and the two points are the difference between the
    /// descenders of the sub-line clearing the row's fill and grazing it. The
    /// content was measured against this height rather than the reverse.
    static let row: CGFloat = 58
    /// The same row in the compact layout, with the detail line dropped.
    static let rowCompact: CGFloat = 40
    /// Sidebar rows.
    static let sidebarRow: CGFloat = 32

    /// Progress bar thickness. Four rather than three: at 3pt a full-width bar
    /// on a dark row reads as a divider between rows rather than as a bar
    /// belonging to one.
    static let track: CGFloat = 4
    /// Hairline width. A real pixel on Retina rather than a blurry point.
    static let hairline: CGFloat = 1
}

/// The window's own furniture: the fake title bar, the panels either side.
///
/// These are the numbers that used to belong to `NavigationSplitView` and the
/// system toolbar. Owning them is the whole reason the app stopped looking like
/// a stock Mac utility — and it also means the column widths are now driven by
/// app state instead of being renegotiated by AppKit on every content change.
enum Chrome {
    /// Height of the custom title bar.
    ///
    /// Everything in the bar — including the three window buttons — is centred
    /// on `barHeight / 2`. The first version left the buttons where AppKit puts
    /// them (centred on 14pt, for a title bar that no longer exists) and pinned
    /// the app's controls to match, which left the whole row jammed against the
    /// top edge with ten points of dead space underneath. It read as clipped.
    /// `WindowChrome` moves the buttons down instead.
    static let barHeight: CGFloat = 44

    /// Left inset that clears the three window buttons. Measured, not guessed:
    /// close sits at x=20 and zoom ends at x=72, so 82 leaves a clean gap
    /// before the app's own first control.
    static let trafficLightInset: CGFloat = 82

    static let sidebarWidth: CGFloat = 216
    static let sidebarMinWidth: CGFloat = 180
    static let sidebarMaxWidth: CGFloat = 320

    static let inspectorWidth: CGFloat = 320
    static let inspectorMinWidth: CGFloat = 280
    static let inspectorMaxWidth: CGFloat = 420

    /// Below this the sidebar and inspector both fold away. Matches the old
    /// `WindowMetrics` threshold so compact behaviour is unchanged.
    static let compactWidth: CGFloat = 620

    /// The narrowest the library is allowed to be squeezed to by the panels
    /// either side of it. Reached by shrinking the panels, never by clipping the
    /// list — see `WindowLayout.columns`.
    static let contentMinWidth: CGFloat = 240

    /// The gap a modal card keeps from the window's edges, and the size below
    /// which it stops shrinking (until the window itself is smaller, at which
    /// point matching the window beats hanging over the side of it).
    ///
    /// **Not the same number as `SettingsChrome.inset`, and it used to be by
    /// accident.** One is the gap outside a card, the other the margin inside
    /// it; they were both `Space.xxl` only because that value happened to suit
    /// both. When the scale moved onto the 8pt grid and `xxl` went 20 to 24,
    /// this quietly took 8pt off the card's width — and in a 380pt window,
    /// which the app supports, that pushed the settings pane under the width
    /// where a download path stops wrapping one character per line.
    /// `WindowLayoutTests` caught it.
    static let modalMargin: CGFloat = Space.xl
    static let modalMinSize = CGSize(width: 320, height: 220)

    /// The smallest the window can be dragged to.
    ///
    /// The smallest the window can be dragged to — small on purpose, because a
    /// Transmission-style narrow strip is a shape this app is meant to work in.
    ///
    /// It was an inline number on the scene, which is also the only place it
    /// takes effect: `NSWindow.contentMinSize` does not survive, because SwiftUI
    /// computes its own minimum from the view tree and installs it after we run.
    /// It lives here so the surfaces that have to survive this size can be
    /// tested against it by name.
    static let minimumWindowSize = CGSize(width: 380, height: 260)

    /// Inside margin for a content pane.
    static let panePadding: CGFloat = 14

    /// The gutter the library pane is set into.
    ///
    /// This is what replaced the hairlines between the columns. The frame of the
    /// window — bar, sidebar, inspector, and this gutter — is one continuous
    /// plane, and the content sits in a rounded well cut out of it. A curve and a
    /// change of tone say "different surface" without anyone having to look at a
    /// drawn line, which is the single most dated thing a Mac window can do.
    static let contentInset: CGFloat = 10

    /// The draggable seam between two columns. Exactly the gutter's width, so the
    /// grab area is the whole visible gap and never overlaps the content.
    static let seamWidth: CGFloat = contentInset
    /// The grip that fades in under the cursor. Invisible until then.
    static let seamGrip: CGFloat = 3

    /// The size a fresh install opens at.
    ///
    /// Medium on purpose: wide enough for the sidebar, a comfortable list and
    /// the details panel at the same time, short enough that the app doesn't
    /// announce itself by filling the screen. Applied by `WindowChrome` on
    /// first launch only — after that macOS remembers whatever you drag it to.
    static let defaultWindowSize = CGSize(width: 1000, height: 640)
}

/// The settings card's grid.
///
/// These were eight inline numbers, and they disagreed with each other in ways
/// that are individually too small to name and collectively obvious:
///
/// - The rail's title sat 12pt from the card's left edge; the pane's title sat
///   20pt from the seam. So the card had two different left margins.
/// - The pane's header sized itself to its tallest child — the 26pt close
///   button — while the rail's header sized itself to a 19pt line of text, so
///   the two titles missed each other by 3pt across the seam.
/// - The rail rows' fill was inset 8pt while the title was inset 12, so the
///   icon column started 4pt to the right of the title above it.
/// - The footer was inset 12pt on the left and bottom, against the pane
///   content's 20 — the card's bottom-left and bottom-right corners had
///   different margins.
///
/// One inset and one header height fix all four.
enum SettingsChrome {
    static let width: CGFloat = 760
    static let height: CGFloat = 540
    static let railWidth: CGFloat = 190
    /// Enough for the icon column and a word. The rail shrinks to this — and no
    /// further — when the card has been shrunk to fit a small window.
    static let railMinWidth: CGFloat = 140
    /// The pane's claim on the card. Below this a setting's name, explanation
    /// and control can't share a line, and the pane starts wrapping mid-word.
    static let paneMinWidth: CGFloat = 340

    /// The card's inside margin, on every edge of both columns: the rail's
    /// title, the icon column beneath it, the footer, the pane's title and the
    /// pane's content all begin exactly here.
    static let inset: CGFloat = Space.xxl

    /// Shared by both columns, which is what puts the two titles on one line.
    ///
    /// 64, which is eight times the base unit. A 16pt semibold title measures
    /// 18.84pt tall, so it centres with 22.6pt above and below — 1.4pt inside
    /// the card's own 24pt inset, and the closest the grid gets. The exact
    /// derived height would be 66.8, which is on no grid at all.
    ///
    /// This was 60 when the inset was 20. Both moved together, and they have to:
    /// the whole point of the number is that the header's title lines up with
    /// the content below it.
    static let headerHeight: CGFloat = 64

    /// A rail row's fill, deliberately `Space.m` wider than the margin on each
    /// side. The row's own padding then puts the icon column back on `inset`,
    /// so the fill has breathing room around the content without the content
    /// moving off the card's left margin.
    static let rowInset: CGFloat = inset - Space.m

    /// Exactly the eight rail rows and the 1pt gaps between them.
    ///
    /// The rail scrolls now — the card shrinks with the window, so the rows are
    /// not always guaranteed their room — and a `ScrollView` is greedy: left to
    /// itself it takes every spare point and pushes the footer to the bottom of
    /// a mostly-empty column. Capping it at the rows' own height means it only
    /// scrolls when it genuinely has to.
    static let railRowsHeight: CGFloat = Size.sidebarRow * 8 + 7

    /// The close button hangs into the right margin by its own slack.
    ///
    /// Its frame is `Size.iconButton` around a `Size.icon` glyph, so it carries
    /// 6.5pt of transparent padding per side. Inset the *frame* by the card's
    /// margin and the glyph lands 26.5pt from the edge, which reads as the
    /// header being lopsided. Inset it by this instead and the glyph's edge sits
    /// on `inset`, level with the title on the other side of the header.
    static let headerTrailing: CGFloat = inset - (Size.iconButton - Size.icon) / 2
}
