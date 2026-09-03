import XCTest
import SwiftUI
@testable import CurrentApp

/// Cover for the states you only reach by *resizing* — the ones nobody thinks
/// to try by hand, and which look fine in a screenshot of a comfortable window.
///
/// Two real bugs are pinned here, both found by dragging a window edge with a
/// panel open:
///
/// - **A 760×540 settings card in a smaller window.** It drew straight past all
///   four edges: clipped everywhere, its close button and its buttons off
///   screen, and the only escape was resizing a window whose controls were now
///   underneath the card.
/// - **Both columns at maximum width in a 690pt window.** 320 + 420 is more than
///   690, so the library in between was asked to be fifty points *narrower than
///   nothing*.
///
/// Both are arithmetic, so both are testable without launching anything — which
/// is the point of `WindowLayout` existing at all. The sweeps matter more than
/// the single cases: a check at one window size is exactly what missed these.
final class WindowLayoutTests: XCTestCase {

    // MARK: - Compact hysteresis

    func testWideWindowIsNotCompact() {
        XCTAssertFalse(WindowLayout.isCompact(width: 1000, wasCompact: false))
        XCTAssertFalse(WindowLayout.isCompact(width: 1000, wasCompact: true))
    }

    func testNarrowWindowIsCompact() {
        XCTAssertTrue(WindowLayout.isCompact(width: 400, wasCompact: false))
        XCTAssertTrue(WindowLayout.isCompact(width: 400, wasCompact: true))
    }

    /// The band between the two thresholds keeps whatever state it was in. This
    /// is the whole reason there are two numbers.
    func testThresholdBandIsSticky() {
        for width in stride(from: WindowLayout.enterCompactWidth, to: WindowLayout.leaveCompactWidth, by: 5) {
            XCTAssertFalse(
                WindowLayout.isCompact(width: width, wasCompact: false),
                "roomy layout should survive \(width)"
            )
            XCTAssertTrue(
                WindowLayout.isCompact(width: width, wasCompact: true),
                "compact layout should survive \(width)"
            )
        }
    }

    /// An unmeasured window is not a narrow one. SwiftUI reports a zero width on
    /// the first layout pass, and treating that as "very small" folded the whole
    /// chrome away for a frame at launch.
    func testUnmeasuredWidthKeepsTheCurrentLayout() {
        XCTAssertFalse(WindowLayout.isCompact(width: 0, wasCompact: false))
        XCTAssertTrue(WindowLayout.isCompact(width: 0, wasCompact: true))
        XCTAssertFalse(WindowLayout.isCompact(width: -1, wasCompact: false))
    }

    /// Dragging an edge slowly across the band must flip the layout once, not
    /// once per pixel. A layout that changes repeatedly on its own is what has
    /// taken this window down before.
    func testDraggingAcrossTheBandFlipsOnce() {
        var state = false
        var flips = 0
        for width in stride(from: 900.0, through: 500.0, by: -1) {
            let next = WindowLayout.isCompact(width: width, wasCompact: state)
            if next != state { flips += 1 }
            state = next
        }
        XCTAssertEqual(flips, 1)
        XCTAssertTrue(state)

        flips = 0
        for width in stride(from: 500.0, through: 900.0, by: 1) {
            let next = WindowLayout.isCompact(width: width, wasCompact: state)
            if next != state { flips += 1 }
            state = next
        }
        XCTAssertEqual(flips, 1)
        XCTAssertFalse(state)
    }

    // MARK: - Columns

    private func columns(
        _ windowWidth: CGFloat,
        sidebar: CGFloat = Chrome.sidebarWidth,
        inspector: CGFloat = Chrome.inspectorWidth,
        showsSidebar: Bool = true,
        showsInspector: Bool = true
    ) -> WindowLayout.Columns {
        WindowLayout.columns(
            windowWidth: windowWidth,
            sidebar: sidebar,
            inspector: inspector,
            showsSidebar: showsSidebar,
            showsInspector: showsInspector,
            minimumContent: Chrome.contentMinWidth,
            minimumSidebar: Chrome.sidebarMinWidth,
            minimumInspector: Chrome.inspectorMinWidth
        )
    }

    func testRoomyWindowGrantsBothPreferencesExactly() {
        let result = columns(1400)
        XCTAssertEqual(result.sidebar, Chrome.sidebarWidth)
        XCTAssertEqual(result.inspector, Chrome.inspectorWidth)
        XCTAssertEqual(result.content, 1400 - Chrome.sidebarWidth - Chrome.inspectorWidth)
        XCTAssertEqual(result.total, 1400, accuracy: 0.001)
    }

    /// The regression. Both seams dragged to their maximum, then the window
    /// shrunk to just above the compact threshold: the library used to come out
    /// at −50pt.
    func testWidestPanelsInTheNarrowestRoomyWindowLeaveTheLibraryUsable() {
        let result = columns(
            WindowLayout.leaveCompactWidth,
            sidebar: Chrome.sidebarMaxWidth,
            inspector: Chrome.inspectorMaxWidth
        )
        XCTAssertGreaterThanOrEqual(result.content, Chrome.contentMinWidth)
        XCTAssertEqual(result.total, WindowLayout.leaveCompactWidth, accuracy: 0.001)
        XCTAssertLessThanOrEqual(result.sidebar, Chrome.sidebarMaxWidth)
        XCTAssertLessThanOrEqual(result.inspector, Chrome.inspectorMaxWidth)
    }

    /// The inspector describes a row in the column it's crowding, so it is the
    /// one that gives way first.
    func testTheInspectorGivesWayBeforeTheSidebar() {
        // 900 with both at max (320 + 420) leaves 160 for the library, 80 short.
        let result = columns(900, sidebar: Chrome.sidebarMaxWidth, inspector: Chrome.inspectorMaxWidth)
        XCTAssertEqual(result.sidebar, Chrome.sidebarMaxWidth, "sidebar should not have been touched yet")
        XCTAssertEqual(result.inspector, Chrome.inspectorMaxWidth - 80, accuracy: 0.001)
        XCTAssertEqual(result.content, Chrome.contentMinWidth, accuracy: 0.001)
    }

    func testHiddenPanelsGiveTheirWidthToTheLibrary() {
        let result = columns(800, showsSidebar: false, showsInspector: false)
        XCTAssertEqual(result.sidebar, 0)
        XCTAssertEqual(result.inspector, 0)
        XCTAssertEqual(result.content, 800)
    }

    /// Narrower than the library's own minimum. There is no good answer, but
    /// there are bad ones: a negative width, or a total that doesn't add up.
    func testWindowNarrowerThanTheMinimumLibraryStillAddsUp() {
        let result = columns(200, sidebar: Chrome.sidebarMaxWidth, inspector: Chrome.inspectorMaxWidth)
        XCTAssertEqual(result.sidebar, 0)
        XCTAssertEqual(result.inspector, 0)
        XCTAssertEqual(result.content, 200)
        XCTAssertEqual(result.total, 200, accuracy: 0.001)
    }

    func testUnmeasuredWindowProducesNoNegativeColumns() {
        let result = columns(0)
        XCTAssertGreaterThanOrEqual(result.content, 0)
        XCTAssertGreaterThanOrEqual(result.sidebar, 0)
        XCTAssertGreaterThanOrEqual(result.inspector, 0)
    }

    /// The sweep that would have caught the original bug: every window width,
    /// every combination of stored preferences, checked against the invariants
    /// rather than against expected numbers.
    func testColumnInvariantsHoldAtEveryWindowWidth() {
        let preferences: [(CGFloat, CGFloat)] = [
            (Chrome.sidebarMinWidth, Chrome.inspectorMinWidth),
            (Chrome.sidebarWidth, Chrome.inspectorWidth),
            (Chrome.sidebarMaxWidth, Chrome.inspectorMaxWidth),
        ]

        for (sidebar, inspector) in preferences {
            for width in stride(from: 120.0, through: 2000.0, by: 10) {
                let result = columns(width, sidebar: sidebar, inspector: inspector)

                XCTAssertGreaterThanOrEqual(result.sidebar, 0, "negative sidebar at \(width)")
                XCTAssertGreaterThanOrEqual(result.inspector, 0, "negative inspector at \(width)")
                XCTAssertGreaterThanOrEqual(result.content, 0, "negative library at \(width)")

                XCTAssertLessThanOrEqual(result.sidebar, sidebar, "sidebar exceeded its preference at \(width)")
                XCTAssertLessThanOrEqual(result.inspector, inspector, "inspector exceeded its preference at \(width)")

                XCTAssertEqual(result.total, width, accuracy: 0.001, "columns don't fill the window at \(width)")
                XCTAssertGreaterThanOrEqual(
                    result.content,
                    min(Chrome.contentMinWidth, width) - 0.001,
                    "library squeezed below its minimum at \(width)"
                )
            }
        }
    }

    /// Widening the window must never make a column narrower. A panel that
    /// shrinks as you make more room reads as a glitch.
    func testColumnsGrowMonotonicallyWithTheWindow() {
        var previous = columns(120, sidebar: Chrome.sidebarMaxWidth, inspector: Chrome.inspectorMaxWidth)
        for width in stride(from: 130.0, through: 2000.0, by: 10) {
            let result = columns(width, sidebar: Chrome.sidebarMaxWidth, inspector: Chrome.inspectorMaxWidth)
            XCTAssertGreaterThanOrEqual(result.sidebar, previous.sidebar - 0.001, "sidebar shrank at \(width)")
            XCTAssertGreaterThanOrEqual(result.inspector, previous.inspector - 0.001, "inspector shrank at \(width)")
            XCTAssertGreaterThanOrEqual(result.content, previous.content - 0.001, "library shrank at \(width)")
            previous = result
        }
    }

    // MARK: - Modal surfaces

    private func modal(_ container: CGSize, preferred: CGSize) -> CGSize {
        WindowLayout.modalSize(
            preferred: preferred,
            container: container,
            margin: Chrome.modalMargin,
            minimum: Chrome.modalMinSize
        )
    }

    private var settingsCard: CGSize {
        CGSize(width: SettingsChrome.width, height: SettingsChrome.height)
    }

    func testCardKeepsItsPreferredSizeWhenThereIsRoom() {
        XCTAssertEqual(modal(CGSize(width: 1400, height: 900), preferred: settingsCard), settingsCard)
    }

    /// The bug from the screenshot: the settings card in a window smaller than
    /// itself. It has to fit, and it has to keep its margin.
    func testCardShrinksToFitASmallWindow() {
        let container = CGSize(width: 600, height: 420)
        let fitted = modal(container, preferred: settingsCard)

        XCTAssertEqual(fitted.width, 600 - Chrome.modalMargin * 2)
        XCTAssertEqual(fitted.height, 420 - Chrome.modalMargin * 2)
        XCTAssertLessThan(fitted.width, container.width)
        XCTAssertLessThan(fitted.height, container.height)
    }

    /// Below the floor the card gives up its margin rather than its fit —
    /// matching the window exactly beats hanging over the side of it, because
    /// what hangs over the side is the close button.
    func testCardMatchesAWindowSmallerThanItsMinimum() {
        let container = CGSize(width: 300, height: 200)
        let fitted = modal(container, preferred: settingsCard)
        XCTAssertEqual(fitted.width, 300)
        XCTAssertEqual(fitted.height, 200)
    }

    func testUnmeasuredWindowLeavesTheCardAtItsPreferredSize() {
        XCTAssertEqual(modal(.zero, preferred: settingsCard), settingsCard)
        XCTAssertEqual(
            modal(CGSize(width: 0, height: 900), preferred: settingsCard).width,
            settingsCard.width
        )
    }

    /// The invariant that actually matters, swept across every window size the
    /// app can be dragged to: a card is never bigger than the window, and never
    /// bigger than it asked to be.
    func testCardNeverExceedsTheWindowAtAnySize() {
        // The cards that size their own height pass `.greatestFiniteMagnitude`
        // for it, which is what `.modalSize(width:)` does for a nil axis.
        let unbounded = CGFloat.greatestFiniteMagnitude
        let cards = [
            settingsCard,
            CGSize(width: 560, height: 520),        // magnet file picker
            CGSize(width: 460, height: unbounded),  // add-magnet card
            CGSize(width: 440, height: unbounded),  // confirm dialog
            CGSize(width: 520, height: unbounded),  // command palette
        ]

        for card in cards {
            for width in stride(from: 100.0, through: 2000.0, by: 10) {
                for height in stride(from: 100.0, through: 1400.0, by: 50) {
                    let container = CGSize(width: width, height: height)
                    let fitted = modal(container, preferred: card)

                    XCTAssertLessThanOrEqual(fitted.width, width + 0.001, "wider than the window at \(container)")
                    XCTAssertLessThanOrEqual(fitted.height, height + 0.001, "taller than the window at \(container)")
                    XCTAssertLessThanOrEqual(fitted.width, card.width, "wider than requested at \(container)")
                    XCTAssertLessThanOrEqual(fitted.height, card.height, "taller than requested at \(container)")
                    XCTAssertGreaterThan(fitted.width, 0)
                    XCTAssertGreaterThan(fitted.height, 0)
                }
            }
        }
    }

    /// Resizing a window with a card open: the card may only ever grow as the
    /// window grows.
    func testCardGrowsMonotonicallyWithTheWindow() {
        var previous = modal(CGSize(width: 100, height: 100), preferred: settingsCard)
        for side in stride(from: 110.0, through: 1400.0, by: 10) {
            let fitted = modal(CGSize(width: side, height: side), preferred: settingsCard)
            XCTAssertGreaterThanOrEqual(fitted.width, previous.width - 0.001, "card narrowed at \(side)")
            XCTAssertGreaterThanOrEqual(fitted.height, previous.height - 0.001, "card shortened at \(side)")
            previous = fitted
        }
    }

    // MARK: - Settings rail

    private func rail(cardWidth: CGFloat) -> CGFloat {
        WindowLayout.settingsRailWidth(
            cardWidth: cardWidth,
            preferred: SettingsChrome.railWidth,
            minimum: SettingsChrome.railMinWidth,
            minimumPane: SettingsChrome.paneMinWidth
        )
    }

    private func showsRail(cardWidth: CGFloat) -> Bool {
        WindowLayout.settingsShowsRail(
            cardWidth: cardWidth,
            minimumRail: SettingsChrome.railMinWidth,
            minimumPane: SettingsChrome.paneMinWidth
        )
    }

    func testRailKeepsItsWidthInAFullSizeCard() {
        XCTAssertTrue(showsRail(cardWidth: SettingsChrome.width))
        XCTAssertEqual(rail(cardWidth: SettingsChrome.width), SettingsChrome.railWidth)
    }

    /// Under the width where both columns fit, the rail folds away and the tabs
    /// move into the header — the pane gets the whole card rather than two
    /// hundred points of it.
    func testRailFoldsAwayWhenTwoColumnsDontFit() {
        let narrow = SettingsChrome.railMinWidth + SettingsChrome.paneMinWidth - 1
        XCTAssertFalse(showsRail(cardWidth: narrow))
        XCTAssertEqual(rail(cardWidth: narrow), 0)

        XCTAssertTrue(showsRail(cardWidth: SettingsChrome.railMinWidth + SettingsChrome.paneMinWidth))
    }

    /// An unmeasured card assumes the roomy layout, so opening settings doesn't
    /// flash the narrow one for a frame.
    func testUnmeasuredCardAssumesTheRail() {
        XCTAssertTrue(showsRail(cardWidth: 0))
        XCTAssertEqual(rail(cardWidth: 0), SettingsChrome.railWidth)
    }

    /// The guarantee that matters, at every card width the window can produce:
    /// whatever the rail does, the pane is never squeezed below its minimum.
    func testThePaneClearsItsMinimumAtEveryCardWidth() {
        for cardWidth in stride(from: SettingsChrome.paneMinWidth, through: 900.0, by: 5) {
            let width = rail(cardWidth: cardWidth)
            XCTAssertGreaterThanOrEqual(
                cardWidth - width,
                SettingsChrome.paneMinWidth - 0.001,
                "pane below its minimum in a \(cardWidth)pt card"
            )
        }
    }

    /// Clamping the card alone only moved the problem: the rail kept all 190pt
    /// of a 360pt card and the pane wrapped a download path one character per
    /// line.
    func testRailGivesWidthToThePaneInAShrunkenCard() {
        let width = rail(cardWidth: 500)
        XCTAssertLessThan(width, SettingsChrome.railWidth)
        XCTAssertGreaterThanOrEqual(width, SettingsChrome.railMinWidth)
        XCTAssertGreaterThanOrEqual(500 - width, SettingsChrome.paneMinWidth - 0.001)
    }

    /// The in-between zone: wide enough for two columns, not wide enough for the
    /// rail's full 190pt. The rail gives up exactly what the pane needs.
    func testRailShrinksToExactlyWhatThePaneLeaves() {
        let cardWidth = SettingsChrome.paneMinWidth + 160
        XCTAssertEqual(rail(cardWidth: cardWidth), 160, accuracy: 0.001)
    }

    func testRailIsEitherAbsentOrUsableAtEveryCardWidth() {
        for cardWidth in stride(from: 60.0, through: 900.0, by: 5) {
            let width = rail(cardWidth: cardWidth)
            XCTAssertLessThanOrEqual(width, SettingsChrome.railWidth, "rail grew past its preference at \(cardWidth)")
            XCTAssertLessThanOrEqual(width, cardWidth, "rail wider than the card at \(cardWidth)")
            // There is no in-between state: a rail is either gone or wide
            // enough to hold an icon and a word. A 40pt stub of one would be
            // worse than not having it.
            XCTAssertTrue(
                width == 0 || width >= SettingsChrome.railMinWidth,
                "unusable \(width)pt rail stub at \(cardWidth)"
            )
        }
    }

    func testRailGrowsMonotonicallyWithTheCard() {
        var previous = rail(cardWidth: 60)
        for cardWidth in stride(from: 65.0, through: 900.0, by: 5) {
            let width = rail(cardWidth: cardWidth)
            XCTAssertGreaterThanOrEqual(width, previous - 0.001, "rail narrowed at \(cardWidth)")
            previous = width
        }
    }

    /// End to end for the smallest window the app allows — a 380pt strip, which
    /// is a shape it's meant to work in. The card fits, and whatever it does
    /// with its rail, the pane still clears its minimum.
    func testTheSmallestAllowedWindowStillHoldsAUsableSettingsCard() {
        let window = Chrome.minimumWindowSize
        let card = modal(window, preferred: settingsCard)

        XCTAssertLessThanOrEqual(card.width, window.width)
        XCTAssertLessThanOrEqual(card.height, window.height)

        XCTAssertFalse(showsRail(cardWidth: card.width), "a 380pt strip has no room for two columns")
        XCTAssertGreaterThanOrEqual(
            card.width - rail(cardWidth: card.width),
            SettingsChrome.paneMinWidth - 0.001,
            "the pane is below its minimum in the smallest window the app allows"
        )
        XCTAssertGreaterThanOrEqual(
            card.height,
            SettingsChrome.headerHeight + Size.sidebarRow,
            "the card is too short for its header and a single row"
        )
    }

    /// And the size the window actually opens at, which is the one most people
    /// will ever see: everything roomy, nothing shrunk.
    func testTheDefaultWindowNeedsNoCompromises() {
        let card = modal(Chrome.defaultWindowSize, preferred: settingsCard)
        XCTAssertEqual(card, settingsCard)
        XCTAssertTrue(showsRail(cardWidth: card.width))
        XCTAssertEqual(rail(cardWidth: card.width), SettingsChrome.railWidth)

        let result = columns(Chrome.defaultWindowSize.width)
        XCTAssertEqual(result.sidebar, Chrome.sidebarWidth)
        XCTAssertEqual(result.inspector, Chrome.inspectorWidth)
        XCTAssertGreaterThan(result.content, Chrome.contentMinWidth)
    }

    // MARK: - Command palette

    private func palette(_ containerHeight: CGFloat, listHeight: CGFloat = 320) -> (top: CGFloat, listHeight: CGFloat) {
        WindowLayout.paletteLayout(
            containerHeight: containerHeight,
            preferredTop: 110,
            preferredListHeight: listHeight,
            chromeHeight: 96,
            minimumListHeight: 46,
            margin: Chrome.modalMargin
        )
    }

    func testPaletteKeepsItsOffsetAndListWhenThereIsRoom() {
        let fit = palette(900)
        XCTAssertEqual(fit.top, 110)
        XCTAssertEqual(fit.listHeight, 320)
    }

    /// The empty space above the palette goes before the list does.
    func testPaletteGivesUpItsOffsetFirst()  {
        let fit = palette(500)
        XCTAssertLessThan(fit.top, 110)
        XCTAssertEqual(fit.listHeight, 320, "the list should still be intact at 500pt")
        XCTAssertLessThanOrEqual(fit.top + 96 + fit.listHeight + Chrome.modalMargin, 500.001)
    }

    func testPaletteShortensItsListOnlyAfterTheOffsetIsGone() {
        let fit = palette(300)
        XCTAssertEqual(fit.top, Chrome.modalMargin)
        XCTAssertLessThan(fit.listHeight, 320)
        XCTAssertGreaterThanOrEqual(fit.listHeight, 46)
    }

    func testPaletteKeepsOneRowInAWindowTooShortForIt() {
        let fit = palette(120)
        XCTAssertGreaterThanOrEqual(fit.listHeight, 46)
        XCTAssertGreaterThanOrEqual(fit.top, 0)
    }

    func testPaletteFitsTheWindowAtEveryHeight() {
        for listHeight in [46.0, 150.0, 320.0] {
            for height in stride(from: 100.0, through: 1400.0, by: 10) {
                let fit = palette(height, listHeight: listHeight)
                XCTAssertGreaterThanOrEqual(fit.top, 0, "negative offset at \(height)")
                XCTAssertGreaterThanOrEqual(fit.listHeight, 0, "negative list at \(height)")
                XCTAssertLessThanOrEqual(fit.top, 110, "offset grew past its preference at \(height)")
                XCTAssertLessThanOrEqual(fit.listHeight, listHeight, "list grew past its content at \(height)")

                // Either everything fits, or the palette is already down to its
                // own furniture and there is nothing left to give.
                let used = fit.top + 96 + fit.listHeight + Chrome.modalMargin
                if used > height {
                    XCTAssertEqual(fit.top, Chrome.modalMargin, accuracy: 0.001, "offset not spent at \(height)")
                    XCTAssertEqual(fit.listHeight, 46, accuracy: 0.001, "list not spent at \(height)")
                }
            }
        }
    }

    func testPaletteUnmeasuredWindowKeepsItsPreferences() {
        let fit = palette(0)
        XCTAssertEqual(fit.top, 110)
        XCTAssertEqual(fit.listHeight, 320)
    }

    // MARK: - The observable wrapper

    /// `WindowMetrics` publishes only on a real flip — per-pixel churn driving
    /// window layout is the failure mode described at the top of AGENTS.md.
    @MainActor
    func testWindowMetricsFollowsTheSameRule() {
        let metrics = WindowMetrics()
        XCTAssertFalse(metrics.isCompact)

        metrics.update(width: 0)
        XCTAssertFalse(metrics.isCompact, "an unmeasured window shouldn't fold the chrome away")

        metrics.update(width: 500)
        XCTAssertTrue(metrics.isCompact)

        metrics.update(width: 650)
        XCTAssertTrue(metrics.isCompact, "650 is inside the band, so the layout should hold")

        metrics.update(width: 700)
        XCTAssertFalse(metrics.isCompact)
    }
}
