import Foundation

public struct TorrentID: Hashable, Comparable, Codable, Sendable {
    public let raw: String

    public init(_ raw: String) { self.raw = raw }

    public static func < (lhs: TorrentID, rhs: TorrentID) -> Bool {
        lhs.raw < rhs.raw
    }
}

public enum TorrentDirection: String, Codable, Sendable {
    case download
    case upload
    case both
}

public enum TorrentState: Equatable, Codable, Sendable {
    case resolving
    case downloading
    case paused(PauseOrigin)
    case seeding
    case completed
    case checking
    case failed(EngineFailure)

    public var isActive: Bool {
        switch self {
        case .downloading, .seeding, .checking: return true
        case .resolving: return true
        default: return false
        }
    }

    public var isPaused: Bool {
        if case .paused = self { return true }
        return false
    }

    public var isComplete: Bool {
        switch self {
        case .seeding, .completed: return true
        default: return false
        }
    }
}

public enum PauseOrigin: Equatable, Codable, Sendable {
    case user
    case seedGoalReached
    case battery
    case cleanup
    case unknown
}

public struct EngineFailure: Equatable, Error, Codable, Sendable {
    public enum Kind: Equatable, Codable, Sendable {
        case savePathUnavailable
        case diskFull
        case networkUnreachable
        case metadataTimedOut
        case duplicateTorrent
        case corruptedData
        case fileExistsConflict
        case engineShutdown
        case unknown
    }

    public var kind: Kind
    public var technicalMessage: String

    public init(kind: Kind, technicalMessage: String) {
        self.kind = kind
        self.technicalMessage = technicalMessage
    }

    public var title: String {
        switch kind {
        case .savePathUnavailable: return "Download folder is unavailable"
        case .diskFull: return "Not enough disk space"
        case .networkUnreachable: return "Network is unreachable"
        case .metadataTimedOut: return "Couldn't find this torrent"
        case .duplicateTorrent: return "Already in your library"
        case .corruptedData: return "Data needs rechecking"
        case .fileExistsConflict: return "Files already exist"
        case .engineShutdown: return "The torrent engine stopped"
        case .unknown: return "Something went wrong"
        }
    }

    public var explanation: String {
        switch kind {
        case .savePathUnavailable:
            return "The drive used by this torrent is disconnected or the folder moved."
        case .diskFull:
            return "There isn't enough space left to continue this download."
        case .networkUnreachable:
            return "No network connection is available right now."
        case .metadataTimedOut:
            return "No peers shared the file details in time. The link may be dead."
        case .duplicateTorrent:
            return "This torrent is already in your library."
        case .corruptedData:
            return "Some downloaded data didn't match what was expected."
        case .fileExistsConflict:
            return "A previous copy of these files is already on disk."
        case .engineShutdown:
            return "The engine shut down unexpectedly."
        case .unknown:
            return "An unexpected error occurred."
        }
    }
}

public struct FilePriority: Equatable, Codable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let skip = FilePriority(rawValue: 0)
    public static let normal = FilePriority(rawValue: 4)
    public static let high = FilePriority(rawValue: 6)
    public static let first = FilePriority(rawValue: 7)

    public var label: String {
        switch rawValue {
        case 0: return "Skip"
        case ..<4: return "Low"
        case 4: return "Normal"
        case ..<7: return "High"
        default: return "First"
        }
    }
}

public struct FileInfo: Hashable, Codable, Sendable {
    public var pathComponents: [String]
    public var size: Int64

    public init(pathComponents: [String], size: Int64) {
        self.pathComponents = pathComponents
        self.size = size
    }

    public var name: String { pathComponents.last ?? "" }
}

public struct TorrentMetadata: Codable, Sendable {
    public var id: TorrentID
    public var displayName: String
    public var totalSize: Int64
    public var pieceCount: Int
    public var pieceLength: Int
    public var files: [FileInfo]

    public init(
        id: TorrentID, displayName: String, totalSize: Int64,
        pieceCount: Int = 0, pieceLength: Int = 0, files: [FileInfo] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.totalSize = totalSize
        self.pieceCount = pieceCount
        self.pieceLength = pieceLength
        self.files = files
    }
}

public struct SwarmSummary: Equatable, Codable, Sendable {
    public var connectedSeeds: Int
    public var connectedPeers: Int
    public var knownSeeds: Int

    public init(connectedSeeds: Int, connectedPeers: Int, knownSeeds: Int) {
        self.connectedSeeds = connectedSeeds
        self.connectedPeers = connectedPeers
        self.knownSeeds = knownSeeds
    }

    public static let empty = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
}

public struct TorrentSnapshot: Identifiable, Equatable, Codable, Sendable {
    public var id: TorrentID
    public var name: String
    public var state: TorrentState
    public var progress: Double
    public var totalBytes: Int64
    public var downloadedBytes: Int64
    public var uploadedBytes: Int64
    public var downloadRate: Double
    public var uploadRate: Double
    public var etaSeconds: TimeInterval?
    public var swarm: SwarmSummary
    public var addedAt: Date
    public var completedAt: Date?
    public var lastActivityAt: Date?
    public var activeSeedSeconds: TimeInterval
    public var saveDirectory: URL
    public var pinned: Bool
    public var hasMetadata: Bool

    public init(
        id: TorrentID,
        name: String,
        state: TorrentState,
        progress: Double,
        totalBytes: Int64,
        downloadedBytes: Int64,
        uploadedBytes: Int64 = 0,
        downloadRate: Double = 0,
        uploadRate: Double = 0,
        etaSeconds: TimeInterval? = nil,
        swarm: SwarmSummary = .empty,
        addedAt: Date = Date(),
        completedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        activeSeedSeconds: TimeInterval = 0,
        saveDirectory: URL = FileManager.default.temporaryDirectory,
        pinned: Bool = false,
        hasMetadata: Bool = true
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.progress = progress
        self.totalBytes = totalBytes
        self.downloadedBytes = downloadedBytes
        self.uploadedBytes = uploadedBytes
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.etaSeconds = etaSeconds
        self.swarm = swarm
        self.addedAt = addedAt
        self.completedAt = completedAt
        self.activeSeedSeconds = activeSeedSeconds
        self.saveDirectory = saveDirectory
        self.pinned = pinned
        self.hasMetadata = hasMetadata
    }

    /// Uploaded divided by downloaded. A ratio of 1 means you gave back as much as you took.
    public var shareRatio: Double {
        guard downloadedBytes > 0 else {
            return uploadedBytes > 0 ? .infinity : 0
        }
        return Double(uploadedBytes) / Double(downloadedBytes)
    }

    public var selectedBytes: Int64 {
        Int64(progress * Double(totalBytes))
    }
}
