import Foundation
import CurrentCore

/// Owns the cleanup plan and executes reversible cleanups.
///
/// Cleanup is always: stop → remove from engine → move content to Trash →
/// record the event. Nothing is ever permanently erased automatically.
@MainActor
final class CleanupCenter: ObservableObject {

    struct Summary: Equatable {
        var bytesReclaimed: Int64
        var torrentsCleaned: Int
    }

    @Published private(set) var plan = CleanupPlan.empty

    private let library: LibraryStore
    private let database: AppDatabase
    /// Set by the environment so the center can surface a toast after cleaning.
    var onCleanupCompleted: ((Summary) -> Void)?

    init(library: LibraryStore, database: AppDatabase) {
        self.library = library
        self.database = database
    }

    func refreshPlan() {
        let snapshots = Array(library.snapshots.values)
        let policies: [TorrentID: SeedPolicy] = Dictionary(
            uniqueKeysWithValues: library.orderedIDs.compactMap { id in
                library.record(for: id).map { (id, $0.policy) }
            }
        )
        plan = CleanupPlanner.plan(
            snapshots: snapshots,
            policies: policies
        )
    }

    /// Runs cleanup for the given candidates. Returns how much was reclaimed.
    @discardableResult
    func performCleanup(_ candidates: [CleanupCandidate]) async -> Summary {
        var reclaimed: Int64 = 0
        var cleaned = 0

        for candidate in candidates {
            let snapshot = candidate.snapshot
            trashContent(for: snapshot)

            await library.engine.remove(snapshot.id, deleteFiles: false)
            await library.remove([snapshot.id], deleteFiles: false)

            reclaimed += candidate.reclaimableBytes
            cleaned += 1

            try? database.recordDecision(
                DecisionRecord(
                    kind: .cleanedUp,
                    torrentID: snapshot.id,
                    torrentName: snapshot.name,
                    date: Date(),
                    reasons: [
                        "Moved to Trash — recoverable",
                        "Reclaimed \(ByteFormatting.bytes(candidate.reclaimableBytes))",
                    ]
                )
            )
        }

        let summary = Summary(bytesReclaimed: reclaimed, torrentsCleaned: cleaned)
        if cleaned > 0 {
            onCleanupCompleted?(summary)
            refreshPlan()
        }
        return summary
    }

    /// Moves the torrent's on-disk content to the macOS Trash.
    private func trashContent(for snapshot: TorrentSnapshot) {
        let manager = FileManager.default
        let directory = snapshot.saveDirectory
        let folderCandidate = directory.appendingPathComponent(snapshot.name)
        let fileCandidate = directory.appendingPathComponent(snapshot.name, isDirectory: false)

        if manager.fileExists(atPath: folderCandidate.path) {
            try? manager.trashItem(at: folderCandidate, resultingItemURL: nil)
        } else if manager.fileExists(atPath: fileCandidate.path) {
            try? manager.trashItem(at: fileCandidate, resultingItemURL: nil)
        }
    }
}
