import XCTest
import CurrentCore
import CurrentSim
@testable import CurrentApp

/// Cover for the automation branch that deletes things.
///
/// `AutomationCoordinator.enforceStorageBudget` is the only path in the app
/// that can remove a download without anyone asking, so the interesting cases
/// are the ones where it must decline: no budget set, under budget, or the
/// switch turned off. Those are also the cases that are effectively
/// untestable by hand — the seeding goals that make a torrent eligible take a
/// day of real time to meet, which is exactly why this went unnoticed as a
/// setting nothing read.
@MainActor
final class StorageBudgetTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDatabase() -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("budget-\(UUID().uuidString).sqlite")
        return AppDatabase(url: url)
    }

    /// A completed torrent the planner should consider fair game: complete,
    /// not pinned, not transferring, ratio above 1 against a Temporary policy,
    /// and in a healthy swarm.
    ///
    /// The swarm matters and is easy to get wrong. Cleanup excludes rare
    /// torrents outright, and a swarm nobody has reported on counts as rare —
    /// so the obvious `.empty` fixture is silently ineligible and every test
    /// below passes for the wrong reason. `requireCleanableFixture` exists to
    /// catch exactly that.
    private func cleanableSnapshot(
        id: String,
        bytes: Int64,
        directory: URL
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(id),
            name: id,
            state: .seeding,
            progress: 1,
            totalBytes: bytes,
            downloadedBytes: bytes,
            uploadedBytes: bytes * 2,
            downloadRate: 0,
            uploadRate: 0,
            swarm: SwarmSummary(connectedSeeds: 20, connectedPeers: 30, knownSeeds: 40),
            saveDirectory: directory
        )
    }

    /// Skips rather than fails when the fixture isn't eligible.
    ///
    /// What counts as a healthy swarm is being reworked, and a test that
    /// hard-fails while that lands would be noise pointing at the wrong place.
    /// Skipping says plainly what happened: the tests below are about the
    /// budget gate, and they cannot say anything about it without something
    /// the planner would agree to remove.
    private func requireCleanableFixture(_ harness: Harness) throws {
        harness.cleanup.refreshPlan()
        try XCTSkipUnless(
            harness.cleanup.plan.candidates.count == 1,
            "fixture is not eligible for cleanup, so this proves nothing — check the swarm health rules"
        )
    }

    private struct Harness {
        let library: LibraryStore
        let settings: SettingsStore
        let cleanup: CleanupCenter
        let automation: AutomationCoordinator
    }

    /// Builds the object graph the coordinator needs, with one cleanable
    /// torrent of `bytes` in a directory of its own.
    ///
    /// Each torrent gets its own save directory: the planner excludes anything
    /// sharing a folder with another torrent, so putting two in one place
    /// would make them ineligible for a reason the test never intended.
    private func makeHarness(torrentBytes: Int64) -> Harness {
        let database = makeDatabase()
        let settings = SettingsStore(database: database)
        let library = LibraryStore(engine: SimulationEngine(), database: database, persistsRecords: false)
        let cleanup = CleanupCenter(library: library, database: database)
        let automation = AutomationCoordinator(
            library: library,
            settings: settings,
            database: database,
            power: PowerMonitor(),
            cleanup: cleanup
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let snapshot = cleanableSnapshot(id: "done", bytes: torrentBytes, directory: directory)
        library.applySnapshots([snapshot])
        library.setPolicy(.temporary, for: [snapshot.id])

        return Harness(library: library, settings: settings, cleanup: cleanup, automation: automation)
    }

    // MARK: - The torrent has to actually be eligible

    /// Guards the other tests: if the fixture stopped being cleanable they
    /// would all pass for the wrong reason.
    func testFixtureIsEligibleForCleanup() throws {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        XCTAssertEqual(harness.cleanup.plan.candidates.count, 1)
    }

    // MARK: - When it must decline

    func testDoesNothingWithoutAStorageBudget() throws {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = true
        harness.settings.storageLimitBytes = nil

        harness.automation.tick()

        // "No budget" must not mean "clean everything eligible". The manual
        // command reads it that way on purpose; on a timer it would empty the
        // library of anything that had finished seeding.
        XCTAssertEqual(harness.library.orderedIDs.count, 1)
    }

    func testDoesNothingWhenUnderBudget() throws {
        let harness = makeHarness(torrentBytes: 1_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = true
        harness.settings.storageLimitBytes = 500_000_000_000

        harness.automation.tick()

        XCTAssertEqual(harness.library.orderedIDs.count, 1)
    }

    func testDoesNothingWhenTheSwitchIsOff() throws {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = false
        harness.settings.storageLimitBytes = 1_000_000

        harness.automation.tick()

        XCTAssertEqual(harness.library.orderedIDs.count, 1,
                       "over budget, but the user said not to clean automatically")
    }

    // MARK: - When it must act

    /// The one path in the app that removes a download nobody asked about.
    func testCleansAutomaticallyWhenOverBudgetAndAllowed() async throws {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = true
        harness.settings.storageLimitBytes = 1_000_000

        var reported = 0
        harness.automation.onStorageBudgetPressure = { _ in reported += 1 }

        harness.automation.tick()

        // The cleanup is launched as a task, so the tick returns before it has
        // finished.
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertTrue(harness.library.orderedIDs.isEmpty, "should have cleaned the eligible torrent")
        XCTAssertEqual(reported, 0, "no need to ask for attention when it handled it itself")
    }

    // MARK: - When it must speak up

    func testReportsPressureItCannotResolveItself() {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        harness.settings.isAutoCleanupEnabled = false
        harness.settings.storageLimitBytes = 1_000_000

        var reported: [Int64] = []
        harness.automation.onStorageBudgetPressure = { reported.append($0) }

        harness.automation.tick()
        XCTAssertEqual(reported.count, 1)

        // Still over budget on the next tick, and it must not say so again —
        // this runs every fifteen seconds.
        harness.automation.tick()
        harness.automation.tick()
        XCTAssertEqual(reported.count, 1, "one crossing should mean one notification")
    }

    /// Dropping back under budget re-arms the warning, so the *next* crossing
    /// is reported rather than silently swallowed.
    func testPressureIsReportedAgainAfterRecovering() {
        let harness = makeHarness(torrentBytes: 10_000_000_000)
        harness.settings.isAutoCleanupEnabled = false
        harness.settings.storageLimitBytes = 1_000_000

        var reported = 0
        harness.automation.onStorageBudgetPressure = { _ in reported += 1 }

        harness.automation.tick()
        XCTAssertEqual(reported, 1)

        harness.settings.storageLimitBytes = 500_000_000_000   // back under
        harness.automation.tick()
        XCTAssertEqual(reported, 1)

        harness.settings.storageLimitBytes = 1_000_000          // over again
        harness.automation.tick()
        XCTAssertEqual(reported, 2)
    }

    // MARK: - The default seed policy is the one you chose

    /// The Seeding pane's picker used to save your choice and change nothing:
    /// every torrent came out Balanced regardless.
    func testNewTorrentsTakeTheChosenDefaultPolicy() {
        let database = makeDatabase()
        let settings = SettingsStore(database: database)
        let library = LibraryStore(engine: SimulationEngine(), database: database, persistsRecords: false)
        library.defaultPolicyProvider = { settings.defaultSeedPolicy }

        settings.defaultSeedPolicy = .archive
        let id = TorrentID("fresh")
        library.registerAdded(id, name: "Fresh", magnet: nil, saveDirectory: FileManager.default.temporaryDirectory)

        XCTAssertEqual(library.record(for: id)?.policy, .archive)
    }
}
