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
    ///
    /// `trigger` is written into every decision it records. Whether the app did
    /// this on its own or was asked to is the first thing you want to know when
    /// a download you were expecting to find is in the Trash, and once
    /// automatic cleanup exists the log can't answer that without being told.
    @discardableResult
    func performCleanup(
        _ candidates: [CleanupCandidate],
        trigger: String = "You asked for a cleanup"
    ) async -> Summary {
        var reclaimed: Int64 = 0
        var cleaned = 0

        for candidate in candidates {
            let snapshot = candidate.snapshot
            // Nothing moved means nothing reclaimed, and then the torrent
            // stays. Removing it anyway is how a storage budget would work its
            // way through the whole library without freeing a byte: each pass
            // still over budget, each pass taking the next one.
            guard library.trashContent(snapshot.id) > 0 else { continue }

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
                        trigger,
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
}
