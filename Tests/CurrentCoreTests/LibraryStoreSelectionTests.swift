import XCTest
import CurrentCore
import CurrentSim
@testable import CurrentApp

/// Regression cover for a crash found by inspecting a real crash report:
/// `EXC_BAD_ACCESS` with `___chkstk_darwin` on the stack — a stack overflow —
/// recursing through `LibraryStore.selection.didSet`.
///
/// `normalizeSelection()` runs from `selection`'s own `didSet`, and in Swift an
/// assignment made inside `didSet` re-enters `didSet`. Writing unconditionally
/// therefore recursed forever. It was reachable in ordinary use: choosing a
/// filter that empties the list makes the table write back a new selection.
///
/// If the guard is ever removed these tests do not fail politely — the test
/// process overflows its stack and dies. That is the point.
@MainActor
final class LibraryStoreSelectionTests: XCTestCase {

    private func makeStore() -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-selection-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return LibraryStore(engine: SimulationEngine(), database: AppDatabase(url: url))
    }

    func testSelectingUnknownIDsTerminatesAndPrunesThem() {
        let store = makeStore()
        store.selection = [TorrentID("ghost-a"), TorrentID("ghost-b")]
        XCTAssertTrue(
            store.selection.isEmpty,
            "ids that aren't in the library should be dropped"
        )
    }

    func testAssigningAnAlreadyCleanSelectionTerminates() {
        let store = makeStore()
        store.selection = []
        XCTAssertTrue(store.selection.isEmpty)
    }

    /// The shape that actually crashed: repeated writes, as happens when the
    /// visible set changes underneath a table that keeps re-reporting its
    /// selection.
    func testRepeatedSelectionWritesTerminate() {
        let store = makeStore()
        for i in 0..<50 {
            store.selection = [TorrentID("missing-\(i)")]
        }
        XCTAssertTrue(store.selection.isEmpty)
    }
}
