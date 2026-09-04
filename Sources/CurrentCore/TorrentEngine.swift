import Foundation

public enum EngineEvent: Sendable {
    case snapshots([TorrentSnapshot])
    case metadataReceived(TorrentID, TorrentMetadata)
    case completed(TorrentID)
    case failed(TorrentID, EngineFailure)
    case removed(TorrentID)

    public var torrentID: TorrentID? {
        switch self {
        case .snapshots: return nil
        case .metadataReceived(let id, _): return id
        case .completed(let id): return id
        case .failed(let id, _): return id
        case .removed(let id): return id
        }
    }
}

public enum AddSource: Sendable {
    case magnet(String)
    case torrentFile(Data)
    /// Serialised engine state used to restore a torrent after relaunch.
    case resumeData(Data)
}

public protocol TorrentEngine: Actor {
    /// Continuous stream of engine state. Emits a coalesced batch roughly once per second.
    var events: AsyncStream<EngineEvent> { get }

    /// Adds content to the session. The returned torrent starts in `.resolving`
    /// for magnets and `.paused(.user)` for complete .torrent payloads.
    func add(_ source: AddSource, saveDirectory: URL) async throws -> TorrentID

    func pause(_ id: TorrentID) async
    func resume(_ id: TorrentID) async

    /// Stops the torrent and forgets it. When `deleteFiles` is true the
    /// downloaded content is erased by the engine; callers that want reversibility
    /// should pass `false` and move files to the Trash themselves.
    func remove(_ id: TorrentID, deleteFiles: Bool) async

    func setFilePriorities(_ id: TorrentID, _ priorities: [FilePriority]) async

    /// Changes where a torrent's files will be written.
    ///
    /// Called on a torrent that has resolved its metadata but hasn't started —
    /// the moment the app asks where a download should go — so in practice this
    /// picks the location rather than moving anything. It is safe on a torrent
    /// with data, which would genuinely be moved, but the app has no such path.
    func setSaveDirectory(_ id: TorrentID, _ directory: URL) async

    func forceRecheck(_ id: TorrentID) async

    /// Serialised session state for restoring after relaunch.
    func resumeData(for id: TorrentID) async -> Data?

    /// Applies every session-wide setting at once: speed limits, connection
    /// and queue caps, listen port, peer discovery and encryption. One call
    /// with one struct so adding a setting doesn't widen this protocol.
    func apply(_ configuration: EngineConfiguration) async
}

extension TorrentEngine {
    public func addMagnet(_ magnet: String, saveDirectory: URL) async throws -> TorrentID {
        try await add(.magnet(magnet), saveDirectory: saveDirectory)
    }

    public func addTorrentFile(_ data: Data, saveDirectory: URL) async throws -> TorrentID {
        try await add(.torrentFile(data), saveDirectory: saveDirectory)
    }
}
