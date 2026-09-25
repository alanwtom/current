import XCTest
import CurrentCore
@testable import CurrentApp

/// What the app does on its own, checked against what it tells the engine and
/// what it writes in the log — the two things "why did this happen?" is
/// answered from.
@MainActor
final class AutomationTests: XCTestCase {

    private struct Harness {
        let engine: RecordingEngine
        let database: AppDatabase
        let library: LibraryStore
        let automation: AutomationCoordinator
    }

    private func makeHarness() -> Harness {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-automation-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let database = AppDatabase(url: url)
        let engine = RecordingEngine()
        let library = LibraryStore(engine: engine, database: database, persistsRecords: false)
        let settings = SettingsStore(database: database)
        let automation = AutomationCoordinator(
            library: library, settings: settings, database: database,
            power: PowerMonitor(), cleanup: CleanupCenter(library: library, database: database)
        )
        return Harness(engine: engine, database: database, library: library, automation: automation)
    }

    private func seeding(_ id: String, ratio: Double, hours: Double) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(id), name: id, state: .seeding, progress: 1,
            totalBytes: 1_000, downloadedBytes: 1_000, uploadedBytes: Int64(ratio * 1_000),
            swarm: SwarmSummary(connectedSeeds: 20, connectedPeers: 30, knownSeeds: 40),
            activeSeedSeconds: hours * 3600
        )
    }

    // MARK: - Seed goals

    func testATorrentThatMetItsGoalIsStoppedOnceAndSaysWhy() async {
        let harness = makeHarness()
        let done = seeding("done", ratio: 1.42, hours: 26)
        let notYet = seeding("not-yet", ratio: 1.42, hours: 2)
        harness.library.applySnapshots([done, notYet])
        harness.library.setPolicy(.balanced, for: [done.id, notYet.id])

        harness.automation.tick()
        harness.automation.tick()

        let paused = await eventually { await harness.engine.paused.contains(done.id) }
        XCTAssertTrue(paused)
        let pauses = await harness.engine.paused
        XCTAssertEqual(pauses, [done.id], "once, and only the torrent whose goal is met")

        let stopped = harness.database.recentDecisions(limit: 10).filter { $0.kind == .seedingStopped }
        XCTAssertEqual(stopped.map(\.torrentID), [done.id])
        XCTAssertFalse(stopped.first?.reasons.isEmpty ?? true, "an automatic stop must carry its reasons")
    }

    func testArchiveNeverStopsSeeding() async {
        let harness = makeHarness()
        let kept = seeding("kept", ratio: 50, hours: 5_000)
        harness.library.applySnapshots([kept])
        harness.library.setPolicy(.archive, for: [kept.id])

        harness.automation.tick()

        // Nothing should arrive; give the tasks a moment to prove it.
        _ = await eventually(timeout: .milliseconds(300)) { false }
        let pauses = await harness.engine.paused
        XCTAssertEqual(pauses, [])
    }

    // MARK: - Magnets that never resolve

    func testAMagnetThatNeverResolvesIsRemovedOnceAndAnnounced() async {
        let harness = makeHarness()
        var announced: [String] = []
        harness.automation.onMagnetTimedOut = { announced.append($0) }

        let stuck = TorrentSnapshot(
            id: TorrentID("stuck"), name: "Stuck", state: .resolving, progress: 0,
            totalBytes: 0, downloadedBytes: 0, addedAt: Date().addingTimeInterval(-121), hasMetadata: false
        )
        let fresh = TorrentSnapshot(
            id: TorrentID("fresh"), name: "Fresh", state: .resolving, progress: 0,
            totalBytes: 0, downloadedBytes: 0, addedAt: Date(), hasMetadata: false
        )
        harness.library.applySnapshots([stuck, fresh])

        harness.automation.tick()
        harness.automation.tick()

        let gone = await eventually { !harness.library.orderedIDs.contains(stuck.id) }
        XCTAssertTrue(gone)
        XCTAssertTrue(harness.library.orderedIDs.contains(fresh.id), "a magnet still inside its two minutes stays")
        XCTAssertEqual(announced, ["Stuck"], "said once, not once per tick")

        let removals = await harness.engine.removed
        XCTAssertEqual(removals.map(\.0), [stuck.id])
        XCTAssertEqual(removals.first?.1, false, "a timed-out magnet has no files to delete, and must never try")
    }
}
