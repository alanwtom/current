import Foundation
import CurrentCore

/// A deterministic torrent engine used for development, previews, and tests.
/// It implements the same `TorrentEngine` contract as the libtorrent-backed
/// engine so the entire app can run against either one.
public actor SimulationEngine: TorrentEngine {

    public let events: AsyncStream<EngineEvent>
    private let continuation: AsyncStream<EngineEvent>.Continuation

    struct Record: Codable {
        var id: TorrentID
        var name: String
        var state: TorrentState
        var totalSize: Int64
        var downloaded: Int64
        var uploaded: Int64
        var downloadRate: Double
        var uploadRate: Double
        var seeds: Int
        var peers: Int
        var addedAt: Date
        var completedAt: Date?
        var seedSeconds: TimeInterval
        var saveDirectory: URL
        var metadata: TorrentMetadata?
        var priorities: [FilePriority]
        var resolveDelayRemaining: TimeInterval?
        var failure: EngineFailure?
    }

    private var records: [TorrentID: Record] = [:]
    private var ticker: Task<Void, Never>?
    private var counter = 0

    // Tunables (useful for previews and tests).
    private let tickInterval: TimeInterval
    private let baseSpeed: Double
    private let resolveDelay: TimeInterval
    private let clock: () -> Date

    public init(
        tickInterval: TimeInterval = 1,
        baseSpeed: Double = 6 * 1024 * 1024,
        resolveDelay: TimeInterval = 2.5,
        clock: @escaping () -> Date = { Date() }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: EngineEvent.self, bufferingPolicy: .bufferingNewest(32)
        )
        self.events = stream
        self.continuation = continuation
        self.tickInterval = tickInterval
        self.baseSpeed = baseSpeed
        self.resolveDelay = resolveDelay
        self.clock = clock
    }

    deinit {
        ticker?.cancel()
        continuation.finish()
    }

    // MARK: - TorrentEngine

    public func add(_ source: AddSource, saveDirectory: URL) async throws -> TorrentID {
        counter += 1
        let id = TorrentID(String(format: "sim%04d", counter))
        let now = clock()

        switch source {
        case .magnet(let uri):
            let name = Self.displayName(fromMagnet: uri, index: counter)
            var record = Record(
                id: id,
                name: name,
                state: .resolving,
                totalSize: Self.size(forName: name),
                downloaded: 0,
                uploaded: 0,
                downloadRate: 0,
                uploadRate: 0,
                seeds: 0,
                peers: 0,
                addedAt: now,
                completedAt: nil,
                seedSeconds: 0,
                saveDirectory: saveDirectory,
                metadata: nil,
                priorities: [],
                resolveDelayRemaining: resolveDelay,
                failure: nil
            )
            record.metadata = Self.metadata(for: record)
            record.priorities = Array(repeating: .normal, count: record.metadata!.files.count)
            records[id] = record

        case .torrentFile(let data):
            let name = "Local torrent \(counter)"
            var record = Record(
                id: id,
                name: name,
                state: .downloading,
                totalSize: Self.size(forName: name),
                downloaded: 0,
                uploaded: 0,
                downloadRate: 0,
                uploadRate: 0,
                seeds: 4,
                peers: 12,
                addedAt: now,
                completedAt: nil,
                seedSeconds: 0,
                saveDirectory: saveDirectory,
                metadata: nil,
                priorities: [.normal],
                resolveDelayRemaining: nil,
                failure: nil
            )
            record.metadata = Self.metadata(for: record)
            record.priorities = Array(repeating: .normal, count: record.metadata!.files.count)
            records[id] = record

        case .resumeData(let data):
            guard let restored = try? JSONDecoder().decode(RestoredRecord.self, from: data) else {
                throw EngineFailure(kind: .corruptedData, technicalMessage: "unreadable resume data")
            }
            var record = restored.record
            record.state = .paused(.user)
            records[record.id] = record
        }

        startTickerIfNeeded()
        return id
    }

    public func pause(_ id: TorrentID) {
        mutate(id) {
            $0.state = $0.state.isComplete ? .paused(.user) : .paused(.user)
            $0.downloadRate = 0
            $0.uploadRate = 0
        }
    }

    public func resume(_ id: TorrentID) {
        mutate(id) {
            if $0.state.isPaused {
                $0.state = $0.state.isComplete ? .seeding : .downloading
            }
        }
    }

    public func remove(_ id: TorrentID, deleteFiles: Bool) {
        records[id] = nil
        continuation.yield(.removed(id))
    }

    public func setFilePriorities(_ id: TorrentID, _ priorities: [FilePriority]) {
        mutate(id) { $0.priorities = priorities }
    }

    public func forceRecheck(_ id: TorrentID) async {
        mutate(id) { $0.downloaded = 0 }
    }

    /// Recorded rather than acted on, so tests and the UI can assert that the
    /// app pushes settings down to the engine without needing a real session.
    public private(set) var lastConfiguration: EngineConfiguration?

    public func apply(_ configuration: EngineConfiguration) {
        lastConfiguration = configuration
    }

    public func resumeData(for id: TorrentID) async -> Data? {
        guard let record = records[id] else { return nil }
        return try? JSONEncoder().encode(RestoredRecord(record: record))
    }

    /// Advances the simulation deterministically; used by tests.
    public func step() async {
        let now = clock()
        let dt = tickInterval

        for (id, record) in records {
            var updated = record

            if updated.failure != nil {
                continue
            }

            if case .resolving = updated.state {
                if let remaining = updated.resolveDelayRemaining {
                    let next = remaining - dt
                    if next <= 0 {
                        updated.resolveDelayRemaining = nil
                        updated.state = .downloading
                        updated.seeds = max(1, updated.seeds)
                        updated.peers = max(8, updated.peers)
                        continuation.yield(.metadataReceived(id, updated.metadata!))
                    } else {
                        updated.resolveDelayRemaining = next
                    }
                }
                records[id] = updated
                continue
            }

            if updated.state.isPaused {
                records[id] = updated
                continue
            }

            let selectedFraction = Self.selectedFraction(updated)
            let target = Int64(Double(updated.totalSize) * selectedFraction)

            var isDownloading = false
            if case .downloading = updated.state { isDownloading = true }

            if isDownloading {
                let speed = baseSpeed * Self.speedFactor(for: id)
                updated.downloadRate = speed
                updated.uploadRate = speed * 0.15
                updated.downloaded = min(target, updated.downloaded + Int64(speed * dt))
                updated.uploaded += Int64(speed * 0.1 * dt)

                if updated.downloaded >= target && target > 0 {
                    updated.state = .completed
                    updated.completedAt = now
                    updated.downloadRate = 0
                    continuation.yield(.completed(id))
                }
            } else if updated.state == .seeding {
                updated.seedSeconds += dt
                updated.uploadRate = baseSpeed * 0.2 * Self.speedFactor(for: id)
                updated.uploaded += Int64(updated.uploadRate * dt)
                updated.downloadRate = 0
            } else {
                updated.downloadRate = 0
                if updated.state != .seeding { updated.uploadRate = 0 }
            }

            // Gentle swarm churn so health states are visible in the UI.
            if updated.state.isActive, Int.random(in: 0..<10) == 0 {
                updated.seeds = max(1, min(140, updated.seeds + Int.random(in: -3...3)))
                updated.peers = max(0, min(200, updated.peers + Int.random(in: -5...5)))
            }

            records[id] = updated
        }

        emitSnapshots()
    }

    // MARK: - Internals

    private func startTickerIfNeeded() {
        guard ticker == nil else { return }
        ticker = Task.detached(priority: .utility) { [weak self] in
            let intervalNanos = UInt64((await self?.tickInterval ?? 1) * 1_000_000_000)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: max(10_000_000, intervalNanos))
                await self?.step()
            }
        }
    }

    private func mutate(_ id: TorrentID, _ change: (inout Record) -> Void) {
        guard var record = records[id] else { return }
        change(&record)
        records[id] = record
    }

    private func emitSnapshots() {
        let snapshots = records.values.map { record -> TorrentSnapshot in
            let selectedFraction = Self.selectedFraction(record)
            let target = Int64(Double(record.totalSize) * selectedFraction)
            let progress = target > 0 ? Double(min(record.downloaded, target)) / Double(target) : 0

            var etaSeconds: TimeInterval?
            if record.downloadRate > 0, record.downloaded < target {
                etaSeconds = Double(target - record.downloaded) / record.downloadRate
            }

            return TorrentSnapshot(
                id: record.id,
                name: record.name,
                state: record.failure.map { TorrentState.failed($0) } ?? record.state,
                progress: progress,
                totalBytes: record.totalSize,
                downloadedBytes: record.downloaded,
                uploadedBytes: record.uploaded,
                downloadRate: record.downloadRate,
                uploadRate: record.uploadRate,
                etaSeconds: etaSeconds,
                swarm: SwarmSummary(
                    connectedSeeds: record.seeds,
                    connectedPeers: record.peers,
                    knownSeeds: record.seeds + 2
                ),
                addedAt: record.addedAt,
                completedAt: record.completedAt,
                activeSeedSeconds: record.seedSeconds,
                saveDirectory: record.saveDirectory,
                hasMetadata: record.metadata != nil
            )
        }
        continuation.yield(.snapshots(Array(snapshots)))
    }

    private static func selectedFraction(_ record: Record) -> Double {
        guard let metadata = record.metadata, !metadata.files.isEmpty else { return 1 }
        let selected = zip(metadata.files, record.priorities).reduce(Int64(0)) { sum, pair in
            pair.1 == .skip ? sum : sum + pair.0.size
        }
        return metadata.totalSize > 0 ? Double(selected) / Double(metadata.totalSize) : 1
    }

    private static func speedFactor(for id: TorrentID) -> Double {
        let hash = abs(id.raw.hashValue)
        return 0.5 + Double(hash % 100) / 100.0
    }

    static func displayName(fromMagnet uri: String, index: Int) -> String {
        if let range = uri.range(of: "dn=") {
            let tail = uri[range.upperBound...]
            if let end = tail.firstIndex(of: "&") {
                let encoded = String(tail[..<end])
                if let decoded = encoded.removingPercentEncoding, !decoded.isEmpty {
                    return decoded
                }
            } else if let decoded = String(tail).removingPercentEncoding, !decoded.isEmpty {
                return decoded
            }
        }
        return "Sample torrent \(index)"
    }

    static func size(forName name: String) -> Int64 {
        let hash = abs(name.hashValue)
        let scale: [Int64] = [
            700 * 1024 * 1024,
            4 * 1024 * 1024 * 1024,
            11 * 1024 * 1024 * 1024,
            18 * 1024 * 1024 * 1024,
        ]
        return scale[hash % scale.count]
    }

    static func metadata(for record: Record) -> TorrentMetadata {
        let stem = (record.name as NSString).deletingPathExtension
        let layouts: [[[String]]] = [
            [[stem + ".mkv"], ["sample", "sample.mp4"]],
            [["ubuntu-26.04-desktop-arm64.iso"]],
            [["disc1", "content.pkg"], ["disc2", "content.pkg"], ["manual.pdf"]],
        ]
        let layout = layouts[abs(stem.hashValue) % layouts.count]
        var files: [FileInfo] = []
        var seed: UInt64 = UInt64(bitPattern: Int64(stem.hashValue))
        for path in layout {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let size = Int64(truncatingIfNeeded: (seed >> 8) % 6_000_000_000) + 50_000_000
            files.append(FileInfo(pathComponents: path, size: size))
        }
        let total = files.reduce(0) { $0 + $1.size }
        return TorrentMetadata(
            id: record.id,
            displayName: record.name,
            totalSize: total,
            pieceCount: Int(total / 262_144) + 1,
            pieceLength: 262_144,
            files: files
        )
    }

    private struct RestoredRecord: Codable {
        var record: Record
    }
}

extension TorrentState {
    var pausedOrigin: PauseOrigin? {
        if case .paused(let origin) = self { return origin }
        return nil
    }
}
