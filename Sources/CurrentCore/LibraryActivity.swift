import Foundation

/// The whole library reduced to what a glanceable surface can show: how much of
/// the queue is finished, how fast it's moving, and the single state that best
/// describes right now.
///
/// This lives in Core rather than in a view because two surfaces need it and
/// they have different lifetimes — the menu bar item exists on every Mac, the
/// notch panel only exists on machines that have a notch. Neither should own
/// the arithmetic.
public struct LibraryActivity: Equatable, Sendable {

    /// One state wins, ordered by what the user most needs to know. A failure
    /// outranks everything: it is the only one that needs action.
    public enum Dominant: Equatable, Sendable {
        case downloading
        case seeding
        case complete
        case failed
    }

    public let done: Int
    public let total: Int
    public let downloadRate: Double
    public let uploadRate: Double
    public let dominant: Dominant

    public init(
        done: Int,
        total: Int,
        downloadRate: Double,
        uploadRate: Double,
        dominant: Dominant
    ) {
        self.done = done
        self.total = total
        self.downloadRate = downloadRate
        self.uploadRate = uploadRate
        self.dominant = dominant
    }

    /// The rate worth showing for the current state: what's going out while
    /// seeding, what's coming in otherwise.
    public var headlineRate: Double {
        dominant == .seeding ? uploadRate : downloadRate
    }

    /// Everything finished, nothing left to wait on.
    public var isFinished: Bool { total > 0 && done == total }

    /// Reduces a set of snapshots. Returns nil for an empty library so callers
    /// can treat "nothing to say" as a distinct case rather than a zeroed
    /// summary that still renders.
    public static func summarize(_ snapshots: [TorrentSnapshot]) -> LibraryActivity? {
        guard !snapshots.isEmpty else { return nil }

        let done = snapshots.filter(\.state.isComplete).count
        let anyFailed = snapshots.contains {
            if case .failed = $0.state { return true }
            return false
        }
        let anyDownloading = snapshots.contains {
            if case .downloading = $0.state { return true }
            return false
        }
        let anySeeding = snapshots.contains { $0.state == .seeding }

        let dominant: Dominant =
            anyFailed ? .failed
            : anyDownloading ? .downloading
            : anySeeding ? .seeding
            : .complete

        return LibraryActivity(
            done: done,
            total: snapshots.count,
            downloadRate: snapshots.reduce(0) { $0 + $1.downloadRate },
            uploadRate: snapshots.reduce(0) { $0 + $1.uploadRate },
            dominant: dominant
        )
    }
}
