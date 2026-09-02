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

    /// Regression for a crash found by running the real libtorrent engine and
    /// handing it a torrent twice: the engine returns the same id, and
    /// `registerAdded` used to insert it again. A duplicated id then trapped
    /// the notch's id-keyed mirror, and duplicate ids also break SwiftUI's
    /// ForEach identity, which requires them to be unique.
    /// Regression for the bug that made every added torrent appear twice.
    ///
    /// `registerAdded` puts the id in the list but cannot produce a snapshot —
    /// that arrives from the engine a moment later. `applySnapshots` guarded on
    /// "did a snapshot already exist?", which is false in exactly that window,
    /// so the first stats batch after any add inserted the id a second time.
    /// Duplicate ids also break SwiftUI's ForEach, which requires them unique.
    func testFirstSnapshotAfterAddDoesNotDuplicateTheRow() {
        let store = makeStore()
        let id = TorrentID("added-then-reported")

        store.registerAdded(
            id, name: "Something", magnet: nil,
            saveDirectory: URL(fileURLWithPath: "/tmp/current-dupe")
        )
        XCTAssertEqual(store.orderedIDs.count, 1)

        // The engine reports it for the first time.
        store.applySnapshots([
            TorrentSnapshot(
                id: id,
                name: "Something",
                state: .downloading,
                progress: 0.1,
                totalBytes: 1_000,
                downloadedBytes: 100,
                addedAt: Date(),
                saveDirectory: URL(fileURLWithPath: "/tmp/current-dupe")
            )
        ])

        XCTAssertEqual(
            store.orderedIDs.filter { $0 == id }.count, 1,
            "the first stats batch after an add must not list the torrent twice"
        )
        XCTAssertEqual(store.visibleTorrents.count, 1)
    }

    func testAddingTheSameTorrentTwiceDoesNotDuplicateIt() {
        let store = makeStore()
        let id = TorrentID("same-torrent")
        let directory = URL(fileURLWithPath: "/tmp/current-dupe")

        store.registerAdded(id, name: "First", magnet: nil, saveDirectory: directory)
        store.registerAdded(id, name: "Second", magnet: nil, saveDirectory: directory)

        XCTAssertEqual(
            store.orderedIDs.filter { $0 == id }.count, 1,
            "re-adding a known torrent must not list it twice"
        )
        XCTAssertEqual(store.record(for: id)?.name, "Second",
                       "the record should still take the newer details")
    }
}
