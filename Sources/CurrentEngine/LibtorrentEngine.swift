import Foundation
import CurrentCore
import LTShim

/// Swift adapter around the libtorrent C shim. Owns the native session and
/// translates engine events into `EngineEvent`s on the app's stream.
public actor LibtorrentEngine: TorrentEngine {

    // MARK: - Event plumbing

    private let continuation: AsyncStream<EngineEvent>.Continuation
    public let events: AsyncStream<EngineEvent>

    /// Context object handed to the C callback. Holds a weak reference to the
    /// owning actor; the session is destroyed before the actor deallocates,
    /// so a nil target simply means "shutting down, drop the event".
    private final class Bridge: @unchecked Sendable {
        weak var target: LibtorrentEngine?
    }

    private var bridge: Bridge
    private nonisolated(unsafe) var session: OpaquePointer?
    private nonisolated(unsafe) let contextPtr: UnsafeMutableRawPointer

    // Bookkeeping so snapshots can carry names and save locations.
    private var displayNames: [TorrentID: String] = [:]
    private var saveDirectories: [TorrentID: URL] = [:]
    private var addedDates: [TorrentID: Date] = [:]

    /// Raw stat row converted on the alert thread so it can cross into the
    /// actor as a Sendable value.
    fileprivate struct RawStats: Sendable {
        var id: String
        var stateCode: Int
        var progress: Double
        var totalWanted: Int64
        var totalDownloaded: Int64
        var totalUploaded: Int64
        var downloadRate: Double
        var uploadRate: Double
        var connectedSeeds: Int32
        var connectedPeers: Int32
        var knownSeeds: Int32
        var seedSeconds: UInt64
        var activeSeconds: UInt64
        var hasMetadata: Bool
    }

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self,
            bufferingPolicy: .bufferingNewest(32)
        )
        self.events = stream
        self.continuation = continuation

        // The callback captures the box directly; `target` is wired up right
        // after session creation, long before the first alert can fire
        // (the worker waits ≥250 ms between polls).
        let box = Bridge()
        self.bridge = box

        let context = Unmanaged.passRetained(box).toOpaque()
        self.contextPtr = context
        self.session = lt_session_create({ context, kind, payload, count in
            guard let context else { return }
            let box = Unmanaged<Bridge>.fromOpaque(context).takeUnretainedValue()
            box.target?.ingest(kind: kind, payload: payload, count: count)
        }, context, Self.dhtStatePath())

        // Wired after creation on the same thread; the engine worker waits
        // ≥250 ms between polls, so no event can observe a nil target.
        box.target = self

        if session == nil {
            // Session creation is near-infallible (only catastrophic
            // allocation/native failures); degrade to a no-op engine
            // instead of crashing the app.
            NSLog("Current: libtorrent session failed to start")
        }
    }

    /// Where the DHT routing table lives between launches.
    ///
    /// Beside the library database rather than in a cache directory: a cold DHT
    /// is the difference between a magnet resolving in seconds and appearing to
    /// do nothing, so this is worth keeping rather than something the system
    /// may evict. A nil-safe empty string disables persistence in the shim,
    /// which is what happens if the directory can't be created.
    private static func dhtStatePath() -> String {
        let manager = FileManager.default
        guard let support = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return ""
        }
        let directory = support.appendingPathComponent("Current", isDirectory: true)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ""
        }
        return directory.appendingPathComponent("dht.state").path
    }

    deinit {
        if let session {
            lt_session_destroy(session)
        }
        Unmanaged<Bridge>.fromOpaque(contextPtr).release()
        // Never leave a pending request's continuation suspended.
        for waiter in resumePending.values {
            waiter.resume(returning: nil)
        }
        continuation.finish()
    }

    // MARK: - Inbound translation (called from the libtorrent alert thread)

    nonisolated func ingest(
        kind: lt_event_kind, payload: UnsafeRawPointer?, count: Int32
    ) {
        guard let payload else { return }

        switch kind {
        case LT_EVENT_STATS:
            let batch = payload.assumingMemoryBound(to: lt_stats_batch.self).pointee
            guard batch.count > 0 else { return }
            let rows = UnsafeBufferPointer(start: batch.rows, count: Int(batch.count))
            let raw: [RawStats] = rows.map { row in
                RawStats(
                    id: String(cString: row.id),
                    stateCode: Int(row.state),
                    progress: row.progress,
                    totalWanted: Int64(bitPattern: row.total_wanted),
                    totalDownloaded: Int64(bitPattern: row.total_downloaded),
                    totalUploaded: Int64(bitPattern: row.total_uploaded),
                    downloadRate: row.download_rate,
                    uploadRate: row.upload_rate,
                    connectedSeeds: row.connected_seeds,
                    connectedPeers: row.connected_peers,
                    knownSeeds: row.known_seeds,
                    seedSeconds: row.seed_seconds,
                    activeSeconds: row.active_seconds,
                    hasMetadata: row.has_metadata != 0
                )
            }
            Task { await self.handleStats(raw) }

        case LT_EVENT_METADATA:
            let info = payload.assumingMemoryBound(to: lt_metadata_info.self).pointee
            let id = TorrentID(String(cString: info.id))
            let name = String(cString: info.name)
            let paths = String(cString: info.file_paths).components(separatedBy: "\n")
            let sizes = UnsafeBufferPointer(
                start: info.file_sizes, count: Int(info.file_count)
            ).map(Int64.init)
            let files = zip(paths, sizes).map { pair in
                FileInfo(
                    pathComponents: pair.0.split(separator: "/").map(String.init),
                    size: pair.1
                )
            }
            let metadata = TorrentMetadata(
                id: id,
                displayName: name,
                totalSize: Int64(bitPattern: info.total_size),
                pieceCount: Int(info.piece_count),
                pieceLength: Int(info.piece_length),
                files: files
            )
            Task { await self.metadataArrived(metadata) }

        case LT_EVENT_COMPLETED:
            let id = TorrentID(String(cString: payload.assumingMemoryBound(to: CChar.self)))
            Task { await self.completed(id) }

        case LT_EVENT_ERROR:
            let info = payload.assumingMemoryBound(to: lt_error_info.self).pointee
            let id = TorrentID(String(cString: info.id))
            let failure = EngineFailure(
                kind: Self.failureKind(for: Int(info.error_kind)),
                technicalMessage: String(cString: info.message)
            )
            Task { await self.failed(id, failure) }

        case LT_EVENT_REMOVED:
            let id = TorrentID(String(cString: payload.assumingMemoryBound(to: CChar.self)))
            Task { await self.forgot(id) }

        case LT_EVENT_RESUME_DATA:
            let info = payload.assumingMemoryBound(to: lt_resume_data_info.self).pointee
            let id = TorrentID(String(cString: info.id))
            let size = Int(info.size)
            let data: Data? = (size > 0 && info.data != nil)
                ? Data(bytes: info.data!, count: size)
                : nil
            Task { await self.resumeDataArrived(id, data) }

        default:
            break
        }
    }

    private func handleStats(_ rows: [RawStats]) {
        var snapshots: [TorrentSnapshot] = []
        snapshots.reserveCapacity(rows.count)

        for row in rows {
            let id = TorrentID(row.id)
            let total = row.totalWanted
            let downloaded =
                total > 0 ? min(row.totalDownloaded, total) : row.totalDownloaded
            let progress = max(0, min(1, row.progress))
            let rate = row.downloadRate

            var etaSeconds: TimeInterval?
            if rate > 0, total > downloaded {
                etaSeconds = Double(total - downloaded) / rate
            } else if progress >= 1 {
                etaSeconds = 0
            }

            let state = Self.state(from: row.stateCode, hasMetadata: row.hasMetadata)

            snapshots.append(
                TorrentSnapshot(
                    id: id,
                    name: displayNames[id] ?? fallbackName(for: id),
                    state: state,
                    progress: progress,
                    totalBytes: total,
                    downloadedBytes: downloaded,
                    uploadedBytes: row.totalUploaded,
                    downloadRate: rate,
                    uploadRate: row.uploadRate,
                    etaSeconds: etaSeconds,
                    swarm: SwarmSummary(
                        connectedSeeds: Int(row.connectedSeeds),
                        connectedPeers: Int(row.connectedPeers),
                        knownSeeds: Int(row.knownSeeds)
                    ),
                    addedAt: addedDates[id] ?? Date(),
                    activeSeedSeconds: TimeInterval(row.seedSeconds),
                    saveDirectory: saveDirectories[id] ?? FileManager.default.temporaryDirectory,
                    hasMetadata: row.hasMetadata
                )
            )
        }

        continuation.yield(.snapshots(snapshots))
    }

    private func metadataArrived(_ metadata: TorrentMetadata) {
        displayNames[metadata.id] = metadata.displayName
        continuation.yield(.metadataReceived(metadata.id, metadata))
    }

    private func completed(_ id: TorrentID) {
        continuation.yield(.completed(id))
    }

    private func failed(_ id: TorrentID, _ failure: EngineFailure) {
        continuation.yield(.failed(id, failure))
    }

    private func forgot(_ id: TorrentID) {
        displayNames[id] = nil
        saveDirectories[id] = nil
        addedDates[id] = nil
        continuation.yield(.removed(id))
    }

    // MARK: - TorrentEngine

    public func add(_ source: AddSource, saveDirectory: URL) async throws -> TorrentID {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)

        var idBuffer = [CChar](repeating: 0, count: 41)
        var errorBuffer = [CChar](repeating: 0, count: 256)
        var errorKind = Int32(LT_ERROR_UNKNOWN)

        switch source {
        case .magnet(let uri):
            let result = uri.withCString { uriC in
                saveDirectory.path.withCString { pathC in
                    withUnsafeMutablePointer(to: &errorKind) { kindPtr in
                        lt_add_magnet(session, uriC, pathC, &idBuffer, &errorBuffer, kindPtr)
                    }
                }
            }
            try Self.throwIfFailed(result, errorBuffer, kind: errorKind)
            let torrentID = TorrentID(Self.cString(idBuffer))
            register(torrentID, saveDirectory: saveDirectory)
            return torrentID

        case .torrentFile(let data), .resumeData(let data):
            let result = data.withUnsafeBytes { raw -> Int32 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return saveDirectory.path.withCString { pathC in
                    withUnsafeMutablePointer(to: &errorKind) { kindPtr in
                        lt_add_torrent_data(session, base, raw.count, pathC, &idBuffer, &errorBuffer, kindPtr)
                    }
                }
            }
            try Self.throwIfFailed(result, errorBuffer, kind: errorKind)
            let torrentID = TorrentID(Self.cString(idBuffer))
            register(torrentID, saveDirectory: saveDirectory)
            return torrentID
        }
    }

    private func register(_ id: TorrentID, saveDirectory: URL) {
        guard !id.raw.isEmpty else { return }
        saveDirectories[id] = saveDirectory
        addedDates[id] = Date()
        if displayNames[id] == nil {
            displayNames[id] = fallbackName(for: id)
        }
    }

    public func pause(_ id: TorrentID) {
        guard let session else { return }
        let result = id.raw.withCString { lt_pause(session, $0) }
        logEngineFailure(result, "pause", id)
    }

    public func resume(_ id: TorrentID) {
        guard let session else { return }
        let result = id.raw.withCString { lt_resume(session, $0) }
        logEngineFailure(result, "resume", id)
    }

    public func remove(_ id: TorrentID, deleteFiles: Bool) {
        guard let session else { return }
        let result = id.raw.withCString { lt_remove(session, $0, deleteFiles ? 1 : 0) }
        logEngineFailure(result, "remove", id)
    }

    public func setSaveDirectory(_ id: TorrentID, _ directory: URL) {
        guard let session else { return }
        // The folder has to exist before libtorrent is pointed at it — the user
        // may have made a new one in the chooser, and `move_storage` on a
        // missing path fails silently from our side.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let result = id.raw.withCString { idC in
            directory.path.withCString { pathC in
                lt_set_save_path(session, idC, pathC)
            }
        }
        logEngineFailure(result, "setSaveDirectory", id)
        guard result == 0 else { return }
        // Snapshots read their directory from this map, not from libtorrent, so
        // it has to move too or the app keeps revealing the old folder in Finder.
        saveDirectories[id] = directory
    }

    public func forceRecheck(_ id: TorrentID) {
        guard let session else { return }
        let result = id.raw.withCString { lt_force_recheck(session, $0) }
        logEngineFailure(result, "recheck", id)
    }

    public func setFilePriorities(_ id: TorrentID, _ priorities: [FilePriority]) {
        guard let session else { return }
        let values = priorities.map { Int32($0.rawValue) }
        guard !values.isEmpty else { return }
        let result = values.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return Int32(0) }
            return id.raw.withCString { id in
                lt_set_file_priorities(session, id, base, Int32(values.count))
            }
        }
        logEngineFailure(result, "set priorities", id)
    }

    /// Most failures here just mean "torrent already gone", which is benign;
    /// anything else is worth a console line during manual testing.
    private func logEngineFailure(_ result: Int32, _ action: String, _ id: TorrentID) {
        guard result != 0 else { return }
        NSLog("Current: engine \(action) failed for torrent \(id.raw.prefix(12))…")
    }

    // MARK: - Resume data

    /// Pending resume-data requests, keyed by torrent. One in flight per
    /// torrent: the shim delivers exactly one event per request, so a second
    /// concurrent caller would orphan the first continuation.
    private var resumePending: [TorrentID: CheckedContinuation<Data?, Never>] = [:]

    /// How long to wait for the shim's resume-data event before giving up.
    private static let resumeDataTimeoutNanos: UInt64 = 3_000_000_000

    public func resumeData(for id: TorrentID) async -> Data? {
        guard let session, resumePending[id] == nil else { return nil }
        let accepted = id.raw.withCString { lt_request_resume_data(session, $0) } == 0
        guard accepted else { return nil }

        return await withCheckedContinuation { continuation in
            resumePending[id] = continuation
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.resumeDataTimeoutNanos)
                await self?.resumeRequestTimedOut(id)
            }
        }
    }

    private func resumeRequestTimedOut(_ id: TorrentID) {
        guard let continuation = resumePending.removeValue(forKey: id) else { return }
        continuation.resume(returning: nil)
    }

    /// Called on the actor when the shim's worker thread delivers a
    /// serialized resume blob (or a failure with `nil` data).
    private func resumeDataArrived(_ id: TorrentID, _ data: Data?) {
        guard let continuation = resumePending.removeValue(forKey: id) else { return }
        continuation.resume(returning: data)
    }

    private func flushResumeWaiters() {
        let waiters = resumePending
        resumePending.removeAll()
        for waiter in waiters.values {
            waiter.resume(returning: nil)
        }
    }

    public func apply(_ configuration: EngineConfiguration) {
        guard let session else { return }
        var settings = lt_settings()
        settings.download_rate = Int32(clamping: configuration.rateLimits.download)
        settings.upload_rate = Int32(clamping: configuration.rateLimits.upload)
        settings.max_connections = Int32(clamping: configuration.maxConnections)
        settings.max_upload_slots = Int32(clamping: configuration.maxUploadSlots)
        settings.active_downloads = Int32(clamping: configuration.maxActiveDownloads)
        settings.active_seeds = Int32(clamping: configuration.maxActiveSeeds)
        settings.listen_port = Int32(clamping: configuration.listenPort)
        settings.enable_dht = configuration.isDHTEnabled ? 1 : 0
        settings.enable_lsd = configuration.isLocalDiscoveryEnabled ? 1 : 0
        settings.enable_port_mapping = configuration.isPortMappingEnabled ? 1 : 0
        settings.encryption_policy = switch configuration.encryption {
        case .allowed: 0
        case .preferred: 1
        case .required: 2
        }

        let result = withUnsafePointer(to: &settings) {
            lt_apply_settings(session, $0)
        }
        if result != 0 {
            NSLog("Current: engine rejected session settings")
        }
    }

    public func shutdown() {
        if let session {
            lt_session_destroy(session)
            self.session = nil
        }
        flushResumeWaiters()
    }

    // MARK: - Mapping helpers

    private static func state(from code: Int, hasMetadata: Bool) -> TorrentState {
        switch code {
        case LT_STATE_RESOLVING: return .resolving
        case LT_STATE_DOWNLOADING: return .downloading
        case LT_STATE_SEEDING: return .seeding
        case LT_STATE_CHECKING: return .checking
        case LT_STATE_FAILED: return .failed(EngineFailure(kind: .unknown, technicalMessage: ""))
        case LT_STATE_PAUSED, LT_STATE_QUEUED: return .paused(.user)
        default:
            return hasMetadata ? .downloading : .resolving
        }
    }

    private static func failureKind(for code: Int) -> EngineFailure.Kind {
        switch code {
        case 1: return .savePathUnavailable
        case 2: return .diskFull
        case 3: return .networkUnreachable
        case 4: return .metadataTimedOut
        case 5: return .duplicateTorrent
        case 6: return .corruptedData
        case 7: return .fileExistsConflict
        case 8: return .engineShutdown
        default: return .unknown
        }
    }


    private nonisolated static func cString(_ chars: [CChar]) -> String {
        let bytes = chars.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func throwIfFailed(_ result: Int32, _ error: [CChar], kind: Int32) throws {
        guard result != 0 else { return }
        let message = cString(error)
        let failureKind = kind != LT_ERROR_UNKNOWN
            ? failureKind(for: Int(kind))
            : classify(message)
        throw EngineFailure(kind: failureKind, technicalMessage: message)
    }

    private static func classify(_ message: String) -> EngineFailure.Kind {
        if message.contains("duplicate") || message.contains("already") {
            return .duplicateTorrent
        }
        if message.contains("No space") || message.contains("quota") {
            return .diskFull
        }
        return .unknown
    }

    private func fallbackName(for id: TorrentID) -> String {
        "Magnet · " + id.raw.prefix(8)
    }
}
