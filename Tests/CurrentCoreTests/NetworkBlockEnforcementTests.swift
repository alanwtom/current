import XCTest
import CurrentCore
@testable import CurrentApp

/// An engine that records what it was told to do, and does nothing else.
///
/// The simulator won't answer the question these tests ask. It models a
/// *working* network, so a paused torrent there simply stops making up
/// progress — which looks identical to a torrent the app never stopped at all.
/// What has to be pinned down is narrower and not visible in any snapshot: that
/// the engine was told.
private actor RecordingEngine: TorrentEngine {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    private(set) var paused: [TorrentID] = []
    private(set) var resumed: [TorrentID] = []

    init() {
        var escaped: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func add(_ source: AddSource, saveDirectory: URL) async throws -> TorrentID {
        TorrentID("added")
    }
    func pause(_ id: TorrentID) { paused.append(id) }
    func resume(_ id: TorrentID) { resumed.append(id) }
    func remove(_ id: TorrentID, deleteFiles: Bool) {}
    func setFilePriorities(_ id: TorrentID, _ priorities: [FilePriority]) {}
    func setSaveDirectory(_ id: TorrentID, _ directory: URL) {}
    func forceRecheck(_ id: TorrentID) async {}
    func resumeData(for id: TorrentID) async -> Data? { nil }
    func apply(_ configuration: EngineConfiguration) {}
}

/// Whether a torrent confined to a connection that has gone is *actually*
/// stopped, as opposed to merely drawn that way.
///
/// The distinction is the whole feature. A blocked snapshot reads as stopped
/// because `blockedByNetwork()` rewrites it (see `BlockedSnapshotTests`), and
/// for a while that was the only thing happening to torrents that arrived after
/// the connection went — at launch, that is every torrent in the library, since
/// restoring from disk happens well after the binding is resolved. They looked
/// stopped, were never told to stop, and started moving bytes again the moment
/// the VPN came back.
@MainActor
final class NetworkBlockEnforcementTests: XCTestCase {

    private func makeStore(engine: RecordingEngine) -> LibraryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-block-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return LibraryStore(
            engine: engine,
            database: AppDatabase(url: url),
            persistsRecords: false
        )
    }

    private func snapshot(_ name: String, _ state: TorrentState) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(name),
            name: name,
            state: state,
            progress: state.isComplete ? 1 : 0.5,
            totalBytes: 1_000,
            downloadedBytes: 500,
            saveDirectory: URL(fileURLWithPath: "/tmp/current-block")
        )
    }

    /// The store hands pauses to the engine from a detached task, so the engine
    /// is polled rather than read once.
    private func pauses(
        on engine: RecordingEngine,
        reaching count: Int,
        timeout: TimeInterval = 2
    ) async -> [TorrentID] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let paused = await engine.paused
            if paused.count >= count { return paused }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await engine.paused
    }

    /// Long enough for a pause that was going to happen to have happened.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(120))
    }

    // MARK: - The gap

    /// **The regression this file exists for.** Launching with no VPN: the
    /// binding resolves and blocks before there is a single torrent in the
    /// library, and the restored ones arrive a moment later.
    func testTorrentsArrivingAfterTheBlockAreStopped() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        // Blocked while the library is empty — nothing to sweep.
        store.setTransfersBlocked(true)
        await settle()
        let sweptAtBlockTime = await engine.paused
        XCTAssertTrue(sweptAtBlockTime.isEmpty, "there was nothing there to stop yet")

        // Restore from disk lands.
        store.applySnapshots([
            snapshot("restored-a", .downloading),
            snapshot("restored-b", .seeding),
        ])

        let paused = await pauses(on: engine, reaching: 2)
        XCTAssertEqual(
            Set(paused), [TorrentID("restored-a"), TorrentID("restored-b")],
            "a torrent restored into a blocked app must be told to stop, not just drawn as stopped"
        )
    }

    /// The count in the decision log has to be the number actually stopped. It
    /// used to be taken at the moment the connection dropped, which on a launch
    /// like the one above is zero — a log entry reading "0 transfers were
    /// stopped" written immediately before six of them were.
    func testTheReportedCountIsWhatWasActuallyStopped() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        var reported: [Int] = []
        store.onStoppedByNetwork = { reported.append($0) }

        store.setTransfersBlocked(true)
        await settle()
        XCTAssertTrue(reported.isEmpty, "nothing was stopped, so nothing should be claimed")

        store.applySnapshots([
            snapshot("a", .downloading),
            snapshot("b", .seeding),
            snapshot("c", .paused(.user)),
        ])
        XCTAssertEqual(reported, [2], "two were live; the third was already stopped by hand")
    }

    /// Blocked, then a torrent goes on being reported once a second. It is told
    /// once — not once per batch for as long as the VPN is down.
    func testATorrentIsToldToStopOnlyOnce() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        var reported: [Int] = []
        store.onStoppedByNetwork = { reported.append($0) }
        store.setTransfersBlocked(true)

        // The engine keeps reporting it as live until it catches up.
        for _ in 0..<5 {
            store.applySnapshots([snapshot("stubborn", .downloading)])
        }
        await settle()

        let paused = await engine.paused
        XCTAssertEqual(paused, [TorrentID("stubborn")])
        XCTAssertEqual(reported, [1], "one stop, reported once")
    }

    // MARK: - What must not be touched

    /// Every one of these is already stopped for a reason of its own, and the
    /// block has no business overwriting it — a completed download re-opened as
    /// "no connection" sends someone off to fix a VPN over a finished torrent.
    func testNothingButLiveTransfersIsStopped() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)
        store.setTransfersBlocked(true)

        store.applySnapshots([
            snapshot("by-hand", .paused(.user)),
            snapshot("done", .completed),
            snapshot("broken", .failed(EngineFailure(kind: .diskFull, technicalMessage: "x"))),
        ])
        await settle()

        let paused = await engine.paused
        XCTAssertTrue(
            paused.isEmpty,
            "only what the engine still considers live should be stopped"
        )
    }

    /// The half that was already right, kept honest: torrents present when the
    /// connection goes are still stopped there and then.
    func testTransfersPresentWhenTheConnectionGoesAreStopped() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        store.applySnapshots([
            snapshot("live", .downloading),
            snapshot("idle", .paused(.user)),
        ])
        store.setTransfersBlocked(true)

        let paused = await pauses(on: engine, reaching: 1)
        XCTAssertEqual(paused, [TorrentID("live")])
    }

    // MARK: - Coming back

    /// The promise the app makes when it stops something: it stays stopped
    /// until you say otherwise. Nothing here may call `resume`.
    func testTheConnectionComingBackResumesNothing() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        store.setTransfersBlocked(true)
        store.applySnapshots([snapshot("a", .downloading)])
        _ = await pauses(on: engine, reaching: 1)

        store.setTransfersBlocked(false)
        await settle()

        let resumed = await engine.resumed
        XCTAssertTrue(
            resumed.isEmpty,
            "a torrent stopped by the block waits for the user, not for the network"
        )
    }

    /// A second outage stops things again. The episode's record of what it
    /// stopped is cleared on the way out, or the same torrent would be skipped
    /// forever after the first time.
    func testASecondOutageStopsTransfersAgain() async {
        let engine = RecordingEngine()
        let store = makeStore(engine: engine)

        store.setTransfersBlocked(true)
        store.applySnapshots([snapshot("a", .downloading)])
        _ = await pauses(on: engine, reaching: 1)

        // Back, started again by hand, and gone once more.
        store.setTransfersBlocked(false)
        store.applySnapshots([snapshot("a", .downloading)])
        store.setTransfersBlocked(true)

        let paused = await pauses(on: engine, reaching: 2)
        XCTAssertEqual(
            paused, [TorrentID("a"), TorrentID("a")],
            "the second outage has to stop it too"
        )
    }
}
