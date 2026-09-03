import XCTest
import CurrentCore

/// Cover for `ListSelection`, which took over click / ⌘-click / ⇧-click and
/// arrow-key behaviour when the library list stopped being an AppKit `List`.
///
/// Nearly every case here is about the two markers. Every "shift-select picked
/// the wrong rows" bug is really the anchor having moved when it shouldn't, or
/// the cursor not having moved when it should.
final class ListSelectionTests: XCTestCase {

    private let order = ["a", "b", "c", "d", "e"].map(TorrentID.init)

    private func ids(_ raws: String...) -> Set<TorrentID> {
        Set(raws.map(TorrentID.init))
    }

    private func id(_ raw: String) -> TorrentID { TorrentID(raw) }

    // MARK: - Clicks

    func testPlainClickReplacesSelectionAndPinsBothMarkers() {
        let out = ListSelection.click(
            .replace, on: id("c"), order: order, selection: ids("a", "b"), anchor: id("a")
        )
        XCTAssertEqual(out.selection, ids("c"))
        XCTAssertEqual(out.anchor, id("c"))
        XCTAssertEqual(out.cursor, id("c"))
    }

    func testCommandClickAddsThenRemoves() {
        let added = ListSelection.click(
            .toggle, on: id("c"), order: order, selection: ids("a"), anchor: id("a")
        )
        XCTAssertEqual(added.selection, ids("a", "c"))

        let removed = ListSelection.click(
            .toggle, on: id("c"), order: order,
            selection: added.selection, anchor: added.anchor, cursor: added.cursor
        )
        XCTAssertEqual(removed.selection, ids("a"))
    }

    func testShiftClickSelectsSpanAndKeepsAnchor() {
        let out = ListSelection.click(
            .extend, on: id("d"), order: order, selection: ids("b"), anchor: id("b"), cursor: id("b")
        )
        XCTAssertEqual(out.selection, ids("b", "c", "d"))
        // The anchor must survive, or the next shift-click extends from "d".
        XCTAssertEqual(out.anchor, id("b"))
        XCTAssertEqual(out.cursor, id("d"))
    }

    func testShiftClickWorksBackwards() {
        let out = ListSelection.click(
            .extend, on: id("a"), order: order, selection: ids("d"), anchor: id("d"), cursor: id("d")
        )
        XCTAssertEqual(out.selection, ids("a", "b", "c", "d"))
    }

    /// Shift-clicking back toward the anchor has to shrink the selection. If the
    /// span were unioned with what was already selected instead of replacing it,
    /// a user narrowing a range would find it stuck at its widest.
    func testShiftClickShrinksRatherThanAccumulates() {
        let wide = ListSelection.click(
            .extend, on: id("e"), order: order, selection: ids("b"), anchor: id("b"), cursor: id("b")
        )
        XCTAssertEqual(wide.selection, ids("b", "c", "d", "e"))

        let narrow = ListSelection.click(
            .extend, on: id("c"), order: order,
            selection: wide.selection, anchor: wide.anchor, cursor: wide.cursor
        )
        XCTAssertEqual(narrow.selection, ids("b", "c"))
    }

    func testShiftClickWithoutAnchorActsLikePlainClick() {
        let out = ListSelection.click(
            .extend, on: id("c"), order: order, selection: [], anchor: nil
        )
        XCTAssertEqual(out.selection, ids("c"))
        XCTAssertEqual(out.anchor, id("c"))
    }

    // MARK: - Arrow keys

    func testArrowIntoEmptySelectionEntersFromTheFarEnd() {
        let down = ListSelection.move(by: 1, order: order, selection: [], anchor: nil, extending: false)
        XCTAssertEqual(down.selection, ids("a"))

        let up = ListSelection.move(by: -1, order: order, selection: [], anchor: nil, extending: false)
        XCTAssertEqual(up.selection, ids("e"))
    }

    func testArrowMovesAndCollapsesSelection() {
        let out = ListSelection.move(
            by: 1, order: order, selection: ids("b", "c"), anchor: id("b"), cursor: id("c"),
            extending: false
        )
        // Moves off the cursor ("c"), not off the anchor, and drops the rest of
        // the range on the way.
        XCTAssertEqual(out.selection, ids("d"))
        XCTAssertEqual(out.anchor, id("d"))
    }

    /// The case that made the cursor necessary. Two ⇧↓ presses in a row have to
    /// grow the range twice; with only an anchor to work from, the second press
    /// starts inside the range it already selected and nothing moves.
    func testShiftArrowKeepsGrowingFromTheAnchor() {
        let once = ListSelection.move(
            by: 1, order: order, selection: ids("b"), anchor: id("b"), cursor: id("b"),
            extending: true
        )
        XCTAssertEqual(once.selection, ids("b", "c"))

        let twice = ListSelection.move(
            by: 1, order: order, selection: once.selection, anchor: once.anchor, cursor: once.cursor,
            extending: true
        )
        XCTAssertEqual(twice.selection, ids("b", "c", "d"))
        XCTAssertEqual(twice.anchor, id("b"))
        XCTAssertEqual(twice.cursor, id("d"))
    }

    /// And ⇧↑ after ⇧↓ has to walk the selection back in again.
    func testShiftArrowBackShrinksTheRange() {
        var out = ListSelection.move(
            by: 1, order: order, selection: ids("b"), anchor: id("b"), cursor: id("b"), extending: true
        )
        out = ListSelection.move(
            by: 1, order: order, selection: out.selection, anchor: out.anchor, cursor: out.cursor,
            extending: true
        )
        out = ListSelection.move(
            by: -1, order: order, selection: out.selection, anchor: out.anchor, cursor: out.cursor,
            extending: true
        )
        XCTAssertEqual(out.selection, ids("b", "c"))
    }

    /// Clamped rather than wrapped: one keypress too many at the bottom should
    /// do nothing, not throw you back to the top of the library.
    func testArrowStopsAtTheEnds() {
        let bottom = ListSelection.move(
            by: 1, order: order, selection: ids("e"), anchor: id("e"), cursor: id("e"), extending: false
        )
        XCTAssertEqual(bottom.selection, ids("e"))

        let top = ListSelection.move(
            by: -1, order: order, selection: ids("a"), anchor: id("a"), cursor: id("a"), extending: false
        )
        XCTAssertEqual(top.selection, ids("a"))
    }

    func testArrowInEmptyListSelectsNothing() {
        let out = ListSelection.move(by: 1, order: [], selection: [], anchor: nil, extending: false)
        XCTAssertTrue(out.selection.isEmpty)
        XCTAssertNil(out.anchor)
    }

    // MARK: - Select all

    func testSelectAllLeavesMarkersAtTheEnds() {
        let out = ListSelection.all(order: order)
        XCTAssertEqual(out.selection.count, order.count)
        XCTAssertEqual(out.anchor, id("a"))
        XCTAssertEqual(out.cursor, id("e"))
    }

    // MARK: - Focus

    func testFocusPrefersTheCursor() {
        let focus = ListSelection.focus(order: order, selection: ids("b", "c", "d"), cursor: id("d"))
        XCTAssertEqual(focus, id("d"))
    }

    /// A section change can drop the cursor's row while leaving others selected.
    func testFocusFallsBackToTheLastSelectedRow() {
        let focus = ListSelection.focus(order: order, selection: ids("b", "d"), cursor: id("z"))
        XCTAssertEqual(focus, id("d"))
    }

    // MARK: - Pruning

    /// The one with real stakes. A selection that outlives the rows it names
    /// means Pause and Remove operate on torrents the user cannot see.
    func testPruningDropsRowsThatLeftTheList() {
        let out = ListSelection.pruned(
            selection: ids("a", "c", "z"),
            anchor: id("z"),
            cursor: id("z"),
            order: order
        )
        XCTAssertEqual(out.selection, ids("a", "c"))
        XCTAssertNil(out.anchor)
        XCTAssertNil(out.cursor)
    }

    func testPruningKeepsMarkersThatSurvived() {
        let out = ListSelection.pruned(
            selection: ids("a", "b"), anchor: id("a"), cursor: id("b"), order: order
        )
        XCTAssertEqual(out.selection, ids("a", "b"))
        XCTAssertEqual(out.anchor, id("a"))
        XCTAssertEqual(out.cursor, id("b"))
    }
}
