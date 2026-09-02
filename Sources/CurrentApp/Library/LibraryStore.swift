import Foundation
import SwiftUI
import CurrentCore
import CurrentEngine
import CurrentSim

/// Everything the library knows about a torrent beyond what the engine
/// reports: user preferences and lifecycle timestamps the app owns.
struct TorrentRecord: Codable {
    var name: String
    var pinned: Bool = false
    var policy: SeedPolicy = .defaultPolicy
    var addedAt: Date
    var completedAt: Date?
    var lastActivityAt: Date?
    /// Set when a magnet was added but metadata hasn't arrived yet, enabling retry.
    var sourceMagnet: String?
    /// Where this torrent's content lives. The engine also reports it, but the
    /// app-owned copy survives relaunch (needed before snapshots arrive).
    var saveDirectory: URL?
}

enum SidebarSection: Hashable {
    case all
    case downloading
    case seeding
    case completed

    case attention
    case readyToClean

    var title: String {
        switch self {
        case .all: return "All"
        case .downloading: return "Downloading"
        case .seeding: return "Seeding"
        case .completed: return "Completed"
        case .attention: return "Needs Attention"
        case .readyToClean: return "Ready to Clean"
        }
    }

    var symbol: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .downloading: return "arrow.down.circle"
        case .seeding: return "arrow.up.circle"
        case .completed: return "checkmark.circle"
        case .attention: return "exclamationmark.triangle"
        case .readyToClean: return "trash.circle"
        }
    }

    static let library: [SidebarSection] = [.all, .downloading, .seeding, .completed]
    static let smart: [SidebarSection] = [.attention, .readyToClean]
}

@MainActor
final class LibraryStore: ObservableObject {

    // Presentation state (low frequency).
    @Published private(set) var orderedIDs: [TorrentID] = []
    @Published private(set) var records: [TorrentID: TorrentRecord] = [:]
    @Published var selection = Set<TorrentID>() {
        didSet { normalizeSelection() }
    }
    @Published var activeSection: SidebarSection = .all
    @Published var searchText = ""

    // High-frequency engine state, deliberately not a single @Published blob:
    // rows observe only their own snapshot through `snapshot(for:)` inside
    // their own body, keeping updates local instead of invalidating the list.
    private(set) var snapshots: [TorrentID: TorrentSnapshot] = [:]
    private(set) var metadataCache: [TorrentID: TorrentMetadata] = [:]
    private(set) var filePriorities: [TorrentID: [FilePriority]] = [:]

    let engine: any TorrentEngine
    private let database: AppDatabase

    init(engine: any TorrentEngine, database: AppDatabase) {
        self.engine = engine
        self.database = database

        for (id, name, pinned, policy, addedAt, directory) in database.loadTorrentRecords() {
            records[id] = TorrentRecord(
                name: name,
                pinned: pinned,
                policy: policy,
                addedAt: addedAt,
                lastActivityAt: nil,
                sourceMagnet: nil,
                saveDirectory: directory
            )
            orderedIDs.append(id)
        }
    }

    // MARK: - Derived queries

    func snapshot(for id: TorrentID) -> TorrentSnapshot? { snapshots[id] }
    func record(for id: TorrentID) -> TorrentRecord? { records[id] }

    var visibleTorrents: [TorrentSnapshot] {
        orderedIDs.compactMap { id -> TorrentSnapshot? in
            guard let snapshot = snapshots[id] else { return nil }
            return matches(snapshot) ? snapshot : nil
        }
    }

    func matches(_ snapshot: TorrentSnapshot) -> Bool {
        matches(snapshot, in: activeSection)
    }

    /// Section is a parameter so callers can ask about a section they are not
    /// currently showing. `count(for:)` used to do that by assigning
    /// `activeSection`, counting, then assigning it back — mutating published
    /// state twice from inside a read, on every sidebar recount.
    func matches(_ snapshot: TorrentSnapshot, in section: SidebarSection) -> Bool {
        if !searchText.isEmpty,
           !snapshot.name.localizedCaseInsensitiveContains(searchText) {
            return false
        }
        switch section {
        case .all:
            return true
        case .downloading:
            if case .resolving = snapshot.state { return true }
            if case .downloading = snapshot.state { return true }
            if case .checking = snapshot.state { return true }
            if case .failed = snapshot.state { return true }
            return false
        case .seeding:
            return snapshot.state == .seeding
        case .completed:
            return snapshot.state == .completed || snapshot.state == .seeding
        case .attention:
            if case .failed = snapshot.state { return true }
            if case .resolving = snapshot.state, !recentlyAdded(snapshot) { return true }
            return false
        case .readyToClean:
            // Membership comes from the cleanup plan, not from this predicate —
            // see RootView.filteredTorrents.
            return true
        }
    }

    private func recentlyAdded(_ snapshot: TorrentSnapshot) -> Bool {
        -snapshot.addedAt.timeIntervalSinceNow < 300
    }

    /// The most relevant torrent for glanceable surfaces: newest active
    /// download, falling back to any active torrent.
    var featuredSnapshot: TorrentSnapshot? {
        let candidates = orderedIDs.compactMap { snapshots[$0] }
        let downloading = candidates.filter { snapshot in
            if case .downloading = snapshot.state { return true }
            return false
        }
        return downloading.first ?? candidates.first(where: { $0.state.isActive })
    }

    var aggregateDownloadRate: Double {
        snapshots.values.reduce(0) { $0 + $1.downloadRate }
    }

    var aggregateUploadRate: Double {
        snapshots.values.reduce(0) { $0 + $1.uploadRate }
    }

    var activeDownloadCount: Int {
        snapshots.values.filter { $0.state.isActive }.count
    }

    /// Bytes currently occupying the disk according to transfer progress.
    var usedStorageBytes: Int64 {
        snapshots.values.reduce(Int64(0)) { used, snapshot in
            if snapshot.state.isComplete {
                return used + max(snapshot.selectedBytes, 0)
            }
            if case .failed = snapshot.state { return used }
            return used + snapshot.downloadedBytes
        }
    }

    func count(for section: SidebarSection) -> Int {
        snapshots.values.filter { matches($0, in: section) }.count
    }

    // MARK: - Event ingestion

    func applySnapshots(_ batch: [TorrentSnapshot]) {
        for var snapshot in batch {
            let existing = snapshots[snapshot.id]
            let record = records[snapshot.id]

            // Overlay app-owned truth onto engine truth.
            snapshot.pinned = record?.pinned ?? false

            if let existing {
                snapshot.completedAt = existing.completedAt
                snapshot.lastActivityAt =
                    (snapshot.downloadRate > 1 || snapshot.uploadRate > 1)
                    ? Date()
                    : existing.lastActivityAt
            }

            if snapshot.progress >= 1 && snapshot.completedAt == nil {
                snapshot.completedAt = Date()
            }

            let previousState = existing?.state
            snapshots[snapshot.id] = snapshot

            // Guard on the list, not on whether a snapshot existed. `existing`
            // is nil for a torrent that was just added by hand — `registerAdded`
            // puts the id in the list but cannot produce a snapshot, that comes
            // from the engine a moment later. Checking `existing` therefore
            // inserted the id a second time on the first stats batch after
            // every add, which duplicated the row and broke ForEach identity.
            if !orderedIDs.contains(snapshot.id) {
                orderedIDs.insert(snapshot.id, at: 0)
            }

            if previousState != nil && previousState != snapshot.state {
                persistRecord(for: snapshot.id, snapshot: snapshot)
            }
        }
        objectWillChange.send()
    }

    func applyMetadata(_ metadata: TorrentMetadata) {
        metadataCache[metadata.id] = metadata
        if filePriorities[metadata.id] == nil {
            filePriorities[metadata.id] = Array(repeating: .normal, count: metadata.files.count)
        }
        objectWillChange.send()
    }

    // MARK: - Actions

    func togglePause(for ids: Set<TorrentID>) {
        for id in ids {
            guard let snapshot = snapshots[id] else { continue }
            Task {
                if snapshot.state.isPaused || snapshot.state == .paused(.user) {
                    await self.engine.resume(id)
                } else if snapshot.state.isActive {
                    await self.engine.pause(id)
                } else if case .failed = snapshot.state {
                    await self.retry(id)
                }
            }
        }
    }

    func remove(_ ids: Set<TorrentID>, deleteFiles: Bool) async {
        for id in ids {
            await engine.remove(id, deleteFiles: false)
            if deleteFiles {
                deleteContentIfPossible(id)
            }
            snapshots[id] = nil
            records[id] = nil
            metadataCache[id] = nil
            filePriorities[id] = nil
            selection.remove(id)
            orderedIDs.removeAll { $0 == id }
            try? database.deleteTorrent(id: id)
        }
        objectWillChange.send()
    }

    func setPinned(_ pinned: Bool, for ids: Set<TorrentID>) {
        for id in ids {
            records[id]?.pinned = pinned
            snapshots[id]?.pinned = pinned
            persistRecord(id: id)
        }
        objectWillChange.send()
    }

    func setPolicy(_ policy: SeedPolicy, for ids: Set<TorrentID>) {
        for id in ids {
            records[id]?.policy = policy
            persistRecord(id: id)
        }
        objectWillChange.send()
    }

    func setPriorities(_ priorities: [FilePriority], for id: TorrentID) {
        filePriorities[id] = priorities
        objectWillChange.send()
        Task { await engine.setFilePriorities(id, priorities) }
    }

    func retry(_ id: TorrentID) async {
        guard let magnet = records[id]?.sourceMagnet else { return }
        let directory = snapshots[id]?.saveDirectory
            ?? records[id]?.saveDirectory
            ?? downloadsDirectory
        await engine.remove(id, deleteFiles: false)
        _ = try? await engine.addMagnet(magnet, saveDirectory: directory)
    }

    var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current")
    }

    // MARK: - Registration helpers

    func registerAdded(
        _ id: TorrentID, name: String?, magnet: String?, saveDirectory: URL
    ) {
        records[id] = TorrentRecord(
            name: name ?? "Resolving…",
            pinned: false,
            policy: defaultPolicy(),
            addedAt: Date(),
            lastActivityAt: nil,
            sourceMagnet: magnet,
            saveDirectory: saveDirectory
        )
        // Adding a torrent that is already here must not list it twice. The
        // engine returns the same id for a duplicate add, so without this the
        // id appears twice in `orderedIDs` — which crashed the notch's mirror
        // (it builds a dictionary keyed by id) and quietly breaks SwiftUI's
        // ForEach identity, since that requires ids to be unique.
        if !orderedIDs.contains(id) {
            orderedIDs.insert(id, at: 0)
        }
        persistRecord(id: id)
        objectWillChange.send()
    }

    func updateNameIfNeeded(_ id: TorrentID, name: String) {
        if records[id]?.name != name {
            records[id]?.name = name
            persistRecord(id: id)
            objectWillChange.send()
        }
    }

    private func defaultPolicy() -> SeedPolicy {
        .defaultPolicy
    }

    private func persistRecord(for id: TorrentID, snapshot: TorrentSnapshot) {
        guard var record = records[id] else { return }
        record.name = snapshot.name
        record.addedAt = snapshot.addedAt
        record.completedAt = snapshot.completedAt
        record.lastActivityAt = snapshot.lastActivityAt
        records[id] = record
        persistRecord(id: id)
    }

    private func persistRecord(id: TorrentID) {
        guard let record = records[id],
              let snapshot = snapshots[id] ?? placeholderSnapshot(record: record, id: id)
        else { return }
        Task.detached(priority: .utility) { [database] in
            try? await MainActor.run {
                try database.upsertTorrent(snapshot, policy: record.policy, pinned: record.pinned)
            }
        }
    }

    private func placeholderSnapshot(record: TorrentRecord, id: TorrentID) -> TorrentSnapshot? {
        TorrentSnapshot(
            id: id,
            name: record.name,
            state: .resolving,
            progress: 0,
            totalBytes: 0,
            downloadedBytes: 0,
            addedAt: record.addedAt,
            saveDirectory: record.saveDirectory ?? downloadsDirectory
        )
    }

    private func deleteContentIfPossible(_ id: TorrentID) {
        guard let snapshot = snapshots[id] else { return }
        let folder = snapshot.saveDirectory.appendingPathComponent(snapshot.name)
        let candidates = [
            folder,
            snapshot.saveDirectory.appendingPathExtension(snapshot.name),
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            try? FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
            return
        }
    }

    /// Drops selected ids that no longer exist.
    ///
    /// The guard is load-bearing, not a micro-optimisation. This runs from
    /// `selection`'s own `didSet`, and in Swift an assignment made inside
    /// `didSet` re-enters `didSet` — so writing unconditionally recurses until
    /// the stack overflows. That is a real crash, not a theoretical one:
    /// picking a filter that empties the list makes the table write back a new
    /// selection, and the app segfaulted on the way down.
    private func normalizeSelection() {
        let known = Set(orderedIDs)
        let pruned = selection.intersection(known)
        guard pruned != selection else { return }
        selection = pruned
    }

    // MARK: - Resume restoration

    func restoreResumeData() async {
        for (id, data) in database.allResumeData() {
            // Re-add where the torrent lived before, not wherever the default
            // downloads folder points today.
            let directory = records[id]?.saveDirectory ?? downloadsDirectory
            _ = try? await engine.add(
                .resumeData(data),
                saveDirectory: directory
            )
        }
    }

    /// Saves resume data for every torrent. Budgeted in wall-clock time so a
    /// wedged engine can never stall app termination; each individual fetch
    /// still runs to completion once started.
    func saveAllResumeData(budget: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: budget)
        for id in orderedIDs {
            guard clock.now < deadline else { break }
            if let data = await engine.resumeData(for: id) {
                try? database.storeResumeData(data, for: id)
            }
        }
    }
}
