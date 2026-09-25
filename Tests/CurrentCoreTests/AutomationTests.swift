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
        var announcedIDs: [TorrentID] = []
        harness.automation.onMagnetTimedOut = { id, name in
            announcedIDs.append(id)
            announced.append(name)
        }

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
        XCTAssertEqual(announcedIDs, [stuck.id], "names which torrent, so the card can tell if it was its own")

        let removals = await harness.engine.removed
        XCTAssertEqual(removals.map(\.0), [stuck.id])
        XCTAssertEqual(removals.first?.1, false, "a timed-out magnet has no files to delete, and must never try")
    }

    // MARK: - Restoring after an upgrade

    /// 1.2 kept every torrent's saved state and never restored one, so the
    /// first launch that can restore brings them all back — including ones
    /// the user watched vanish weeks ago. They come back paused, once.
    func testTheFirstWorkingRestoreBringsEverythingBackPausedOnce() async throws {
        let harness = makeHarness()
        try harness.database.storeResumeData(Data("one".utf8), for: TorrentID("one"))
        try harness.database.storeResumeData(Data("two".utf8), for: TorrentID("two"))

        let first = await harness.library.restoreResumeData()
        XCTAssertEqual(first.pausedForUpgrade, 2)
        let firstHolds = await harness.engine.added.map(\.1)
        XCTAssertEqual(firstHolds, [true, true], "upgrading must not start anything on its own")

        // The next launch is an ordinary one: back exactly as saved.
        let nextLaunch = LibraryStore(engine: harness.engine, database: harness.database, persistsRecords: false)
        let second = await nextLaunch.restoreResumeData()
        XCTAssertEqual(second.pausedForUpgrade, 0)
        let secondHolds = await harness.engine.added.dropFirst(2).map(\.1)
        XCTAssertEqual(Array(secondHolds), [false, false])
    }

    /// The magnet timeout counts from when a torrent arrived, and a restored
    /// one "arrives" at launch. One still looking for its file details was
    /// deleted from the library two minutes after every launch.
    func testARestoredTorrentIsNotTimedOutLikeAFreshMagnet() async throws {
        let harness = makeHarness()
        var announced: [String] = []
        harness.automation.onMagnetTimedOut = { _, name in announced.append(name) }
        try harness.database.storeResumeData(Data("blob".utf8), for: TorrentID("added"))
        _ = await harness.library.restoreResumeData()

        harness.library.applySnapshots([TorrentSnapshot(
            id: TorrentID("added"), name: "Restored", state: .resolving, progress: 0,
            totalBytes: 0, downloadedBytes: 0, addedAt: Date().addingTimeInterval(-600), hasMetadata: false
        )])
        harness.automation.tick()

        _ = await eventually(timeout: .milliseconds(300)) { false }
        XCTAssertTrue(harness.library.orderedIDs.contains(TorrentID("added")))
        XCTAssertEqual(announced, [])
        let removals = await harness.engine.removed
        XCTAssertTrue(removals.isEmpty)
    }
}
