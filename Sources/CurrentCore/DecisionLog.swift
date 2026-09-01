import Foundation

/// A record of an automated decision, written in language a user can read.
public struct DecisionRecord: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case seedingStopped = "Seeding stopped"
        case seedingKept = "Kept seeding"
        case cleanupProposed = "Suggested for cleanup"
        case cleanedUp = "Cleaned up"
        case pausedForBattery = "Paused to save battery"
        case magnetTimedOut = "Magnet never resolved"
    }

    public var id: UUID
    public var kind: Kind
    public var torrentID: TorrentID?
    public var torrentName: String?
    public var date: Date
    public var reasons: [String]

    public init(
        id: UUID = UUID(),
        kind: Kind,
        torrentID: TorrentID? = nil,
        torrentName: String? = nil,
        date: Date = Date(),
        reasons: [String]
    ) {
        self.id = id
        self.kind = kind
        self.torrentID = torrentID
        self.torrentName = torrentName
        self.date = date
        self.reasons = reasons
    }
}

public protocol DecisionLogStore: Sendable {
    func record(_ decision: DecisionRecord) async
    func recent(limit: Int) async -> [DecisionRecord]
}
