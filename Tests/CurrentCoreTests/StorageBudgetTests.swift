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
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
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

    /// Fails, loudly, when the fixture isn't eligible.
    ///
    /// This used to skip, on the reasoning that a failure here pointed at the
    /// wrong place. But a skip is silent in CI, and it made every test below
    /// pass without testing anything — which is how automatic cleanup went on
    /// being unable to remove a single torrent for everyone who hadn't changed
    /// their download folder, with all of these reported green.
    private func requireCleanableFixture(_ harness: Harness, file: StaticString = #filePath, line: UInt = #line) throws {
        harness.cleanup.refreshPlan()
        XCTAssertEqual(
            harness.cleanup.plan.candidates.count, 1,
            "fixture is not eligible for cleanup: \(harness.cleanup.plan.kept.first?.reasons ?? [])",
            file: file, line: line
        )
    }

    private struct Harness {
        let library: LibraryStore
        let settings: SettingsStore
        let cleanup: CleanupCenter
        let automation: AutomationCoordinator
        /// The torrent's one file, really on disk.
        let content: URL
        /// Everything the app asked to move to the Trash.
        let trashed: TrashRecorder
    }

    /// Builds the object graph the coordinator needs, with one cleanable
    /// torrent of `bytes` whose file really exists.
    private func makeHarness(torrentBytes: Int64) throws -> Harness {
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

        let directory = try makeScratchDirectory(self, "budget")
        let content = directory.appendingPathComponent("done")
        try Data("payload".utf8).write(to: content)
        let trashed = TrashRecorder()
        library.contentTrash.moveToTrash = trashed.move

        let snapshot = cleanableSnapshot(id: "done", bytes: torrentBytes, directory: directory)
        library.applySnapshots([snapshot])
        library.applyMetadata(TorrentMetadata(
            id: snapshot.id, displayName: "done", totalSize: torrentBytes,
            pieceCount: 1, pieceLength: 16_384,
            files: [FileInfo(pathComponents: ["done"], size: torrentBytes)]
        ))
        library.setPolicy(.temporary, for: [snapshot.id])

        return Harness(library: library, settings: settings, cleanup: cleanup,
                       automation: automation, content: content, trashed: trashed)
    }

    // MARK: - The torrent has to actually be eligible

    /// Guards the other tests: if the fixture stopped being cleanable they
    /// would all pass for the wrong reason.
    func testFixtureIsEligibleForCleanup() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
    }

    /// Cleanup that can't find the files must leave the torrent alone. If it
    /// removed it anyway, a budget would work its way through the whole
    /// library — still over budget after every pass — without freeing a byte.
    func testATorrentWhoseFilesAreGoneIsNotCleanedAway() async throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        try FileManager.default.removeItem(at: harness.content)

        let summary = await harness.cleanup.performCleanup(harness.cleanup.plan.candidates)
        XCTAssertEqual(summary.torrentsCleaned, 0)
        XCTAssertEqual(summary.bytesReclaimed, 0)
        XCTAssertEqual(harness.library.orderedIDs.count, 1)
    }

    /// Two torrents in the default folder are not "sharing files". Treating
    /// them as if they were excluded every torrent in the library.
    func testTorrentsInTheSameFolderAreStillCleanable() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
        let neighbour = cleanableSnapshot(
            id: "neighbour", bytes: 5_000_000_000,
            directory: harness.content.deletingLastPathComponent()
        )
        harness.library.applySnapshots([neighbour])
        harness.library.setPolicy(.temporary, for: [neighbour.id])
        harness.cleanup.refreshPlan()
        XCTAssertEqual(Set(harness.cleanup.plan.candidates.map(\.id)), [TorrentID("done"), neighbour.id])
    }

    // MARK: - When it must decline

    func testDoesNothingWithoutAStorageBudget() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
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
        let harness = try makeHarness(torrentBytes: 1_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = true
        harness.settings.storageLimitBytes = 500_000_000_000

        harness.automation.tick()

        XCTAssertEqual(harness.library.orderedIDs.count, 1)
    }

    func testDoesNothingWhenTheSwitchIsOff() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
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
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
        try requireCleanableFixture(harness)
        harness.settings.isAutoCleanupEnabled = true
        harness.settings.storageLimitBytes = 1_000_000

        var reported = 0
        harness.automation.onStorageBudgetPressure = { _ in reported += 1 }

        harness.automation.tick()

        // The cleanup is launched as a task, so the tick returns before it has
        // finished.
        let cleaned = await eventually { harness.library.orderedIDs.isEmpty }
        XCTAssertTrue(cleaned, "should have cleaned the eligible torrent")
        XCTAssertEqual(harness.trashed.urls, [harness.content], "exactly the torrent's file, and nothing else")
        XCTAssertEqual(reported, 0, "no need to ask for attention when it handled it itself")
    }

    // MARK: - When it must speak up

    func testReportsPressureItCannotResolveItself() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
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
    func testPressureIsReportedAgainAfterRecovering() throws {
        let harness = try makeHarness(torrentBytes: 10_000_000_000)
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

/// Stands in for the Trash: records what it was given, and moves it out of
/// the way so a later existence check sees it gone.
final class TrashRecorder: @unchecked Sendable {
    private(set) var urls: [URL] = []
    private let bin: URL

    init() {
        bin = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-trash-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: bin) }

    func move(_ url: URL) throws {
        urls.append(url)
        try FileManager.default.moveItem(
            at: url, to: bin.appendingPathComponent("\(urls.count)-\(url.lastPathComponent)")
        )
    }
}
