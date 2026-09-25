import XCTest
import CurrentCore
@testable import CurrentApp

/// An engine that records what it was told to do, and does nothing else.
///
/// The simulator won't answer the questions these tests ask. It models a
/// *working* network, so a paused torrent there simply stops making up
/// progress — which looks identical to a torrent the app never stopped at all.
/// What has to be pinned down is narrower and not visible in any snapshot: that
/// the engine was told.
actor RecordingEngine: TorrentEngine {
    let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    private(set) var paused: [TorrentID] = []
    private(set) var resumed: [TorrentID] = []
    private(set) var removed: [(TorrentID, Bool)] = []
    private(set) var added: [(AddSource, Bool)] = []

    init() {
        var escaped: AsyncStream<EngineEvent>.Continuation!
        events = AsyncStream { escaped = $0 }
        continuation = escaped
    }

    func add(_ source: AddSource, saveDirectory: URL, held: Bool) async throws -> TorrentID {
        added.append((source, held))
        return TorrentID("added")
    }
    func pause(_ id: TorrentID) { paused.append(id) }
    func resume(_ id: TorrentID) { resumed.append(id) }
    func remove(_ id: TorrentID, deleteFiles: Bool) { removed.append((id, deleteFiles)) }
    func setFilePriorities(_ id: TorrentID, _ priorities: [FilePriority]) {}
    func setSaveDirectory(_ id: TorrentID, _ directory: URL) {}
    func forceRecheck(_ id: TorrentID) async {}
    func resumeData(for id: TorrentID) async -> Data? { nil }
    func apply(_ configuration: EngineConfiguration) {}
}

/// A scratch directory that is removed when the test ends.
func makeScratchDirectory(_ test: XCTestCase, _ label: String = "scratch") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("current-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url.resolvingSymlinksInPath()
}

/// Polls until `condition` holds or `timeout` passes, instead of sleeping a
/// fixed time and hoping. Returns whether it held.
@MainActor
func eventually(
    timeout: Duration = .seconds(5),
    _ condition: @MainActor () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// The first event `match` accepts, or nil after `timeout`. A stream that
/// never produces the event fails the test instead of hanging the suite.
func firstEvent<T: Sendable>(
    in stream: AsyncStream<EngineEvent>,
    timeout: Duration = .seconds(5),
    where match: @escaping @Sendable (EngineEvent) -> T?
) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask {
            for await event in stream {
                if let found = match(event) { return found }
            }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}
