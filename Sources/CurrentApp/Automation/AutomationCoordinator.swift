import Foundation
import CurrentCore

/// Runs the automation loop: seed goals, cleanup pressure, resolving
/// timeouts, and power-aware pausing. Every action it takes is written to
/// the decision log so the UI can always answer "why did this happen?".
@MainActor
final class AutomationCoordinator {

    private let library: LibraryStore
    private let settings: SettingsStore
    private let database: AppDatabase
    private let power: PowerMonitor
    private let cleanup: CleanupCenter

    /// Told when a magnet is given up on, so the app can say so.
    ///
    /// It used to write a decision-log entry and nothing else. From the outside
    /// that is indistinguishable from the app ignoring the link: the row
    /// disappears two minutes after you clicked something, with the explanation
    /// filed away in a tab you had no reason to open.
    var onMagnetTimedOut: ((String) -> Void)?

    /// Told when the library is over its storage budget and the app can't fix
    /// it on its own — either automatic cleanup is off, or it is on and
    /// nothing is eligible. Deliberately *not* called when automatic cleanup
    /// is about to handle it: a notification telling you about a problem the
    /// app is already solving is noise.
    var onStorageBudgetPressure: ((_ overBy: Int64) -> Void)?

    /// Torrents this coordinator paused automatically; resumed when conditions clear.
    private var batteryPaused = Set<TorrentID>()
    private var seedingStoppedLogged = Set<TorrentID>()
    private var cleanupProposedLogged = Set<TorrentID>()
    /// Magnets whose resolve timeout has already been handled, so a stale
    /// row can't re-trigger removal + logging on every tick.
    private var resolveTimeoutsHandled = Set<TorrentID>()

    /// True while an automatic cleanup is in flight. The tick is every 15 s and
    /// a cleanup is async, so without this a slow one would be started again
    /// underneath itself and the same files trashed twice.
    private var isCleaningAutomatically = false
    /// Whether we've already said the budget needs attention. Cleared when the
    /// library drops back under, so one crossing means one notification rather
    /// than one every fifteen seconds until something changes.
    private var budgetPressureNotified = false

    /// Held while downloads are running and the user asked us to keep the Mac
    /// awake. Releasing it is what lets the machine idle-sleep again, so it
    /// must be dropped the moment either condition stops being true.
    private var sleepAssertion: NSObjectProtocol?

    private var timer: Timer?
    static let tickInterval: TimeInterval = 15
    static let resolveTimeout: TimeInterval = 120

    init(
        library: LibraryStore,
        settings: SettingsStore,
        database: AppDatabase,
        power: PowerMonitor,
        cleanup: CleanupCenter
    ) {
        self.library = library
        self.settings = settings
        self.database = database
        self.power = power
        self.cleanup = cleanup

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func tick() {
        enforceSeedGoals()
        enforcePowerPolicy()
        enforceSleepPolicy()
        enforceStorageBudget()
        watchResolveTimeouts()
    }

    // MARK: - Seed goals

    private func enforceSeedGoals() {
        for snapshot in library.snapshots.values {
            guard snapshot.state == .seeding else {
                if !snapshot.state.isComplete {
                    // A torrent that starts downloading again resets the "stopped" memory.
                    seedingStoppedLogged.remove(snapshot.id)
                }
                continue
            }

            guard let record = library.record(for: snapshot.id) else { continue }
            let decision = SeedEvaluator.evaluate(
                snapshot: snapshot,
                policy: record.policy
            )

            guard decision.shouldStop, !seedingStoppedLogged.contains(snapshot.id) else { continue }

            seedingStoppedLogged.insert(snapshot.id)
            Task {
                await self.library.engine.pause(snapshot.id)
            }
            log(
                .seedingStopped,
                torrentID: snapshot.id,
                name: snapshot.name,
                reasons: decision.reasons
            )

            if case .temporary = record.policy {
                log(
                    .cleanupProposed,
                    torrentID: snapshot.id,
                    name: snapshot.name,
                    reasons: ["Temporary policy reached its goal", "Ready to clean whenever you want"]
                )
            }
        }
    }

    // MARK: - Power

    private func enforcePowerPolicy() {
        let onBattery = power.isOnBattery || power.isLowPowerMode

        if onBattery && settings.pauseDownloadsOnBattery {
            for snapshot in library.snapshots.values where snapshot.state == .downloading {
                if batteryPaused.insert(snapshot.id).inserted {
                    Task { await self.library.engine.pause(snapshot.id) }
                    log(
                        .pausedForBattery,
                        torrentID: snapshot.id,
                        name: snapshot.name,
                        reasons: ["Your Mac is running on battery"]
                    )
                }
            }
        } else if !onBattery || !settings.pauseDownloadsOnBattery {
            for id in batteryPaused {
                Task { await self.library.engine.resume(id) }
            }
            if !batteryPaused.isEmpty {
                batteryPaused.removeAll()
            }
        }
    }

    // MARK: - Sleep

    /// Keeps the Mac awake while something is actually transferring.
    ///
    /// This is an *idle* sleep assertion, which is the honest kind: it stops
    /// the Mac dozing off while a download runs, and it deliberately does not
    /// fight the lid. Closing a laptop is an unambiguous instruction to sleep,
    /// and an app that refused would be a battery bug people can't diagnose.
    /// The settings copy says so.
    private func enforceSleepPolicy() {
        let isTransferring = library.snapshots.values.contains { $0.state == .downloading }
        let shouldStayAwake = settings.preventSleepWhileDownloading && isTransferring

        if shouldStayAwake, sleepAssertion == nil {
            sleepAssertion = ProcessInfo.processInfo.beginActivity(
                options: .idleSystemSleepDisabled,
                reason: "Downloading"
            )
        } else if !shouldStayAwake, let assertion = sleepAssertion {
            ProcessInfo.processInfo.endActivity(assertion)
            sleepAssertion = nil
        }
    }

    // MARK: - Storage budget

    /// Acts on the storage budget: cleans up to it if allowed, says so if not.
    ///
    /// Both halves need a budget to exist. With no limit set there is nothing
    /// to be over, and that guard is load-bearing — the manual "clean now"
    /// command treats "no limit" as "everything eligible", which is the right
    /// answer when a person just asked for it and a catastrophic one on a
    /// timer.
    private func enforceStorageBudget() {
        guard let limit = settings.storageLimitBytes else {
            budgetPressureNotified = false
            return
        }
        let used = library.usedStorageBytes
        guard used > limit else {
            budgetPressureNotified = false
            return
        }
        let overBy = used - limit

        cleanup.refreshPlan()
        // `candidates` has already been through the eligibility gate: complete,
        // seed goals met, not pinned, not active, and rare swarms excluded.
        // Ranking happens after that gate, never instead of it.
        let candidates = cleanup.plan.candidatesToReach(freeBytesTarget: overBy)

        if settings.isAutoCleanupEnabled, !candidates.isEmpty, !isCleaningAutomatically {
            isCleaningAutomatically = true
            Task { [weak self] in
                guard let self else { return }
                await self.cleanup.performCleanup(
                    candidates,
                    trigger: "Over your storage budget by \(ByteFormatting.bytes(overBy))"
                )
                self.isCleaningAutomatically = false
            }
            return
        }

        // Nothing the app can do by itself, so this is genuinely yours to look
        // at: either you've turned automatic cleanup off, or everything left is
        // pinned, still seeding towards a goal, or too rare to remove.
        guard !budgetPressureNotified else { return }
        budgetPressureNotified = true
        log(
            .cleanupProposed,
            torrentID: nil,
            name: nil,
            reasons: [
                "Using \(ByteFormatting.bytes(used)) against a \(ByteFormatting.bytes(limit)) budget",
                settings.isAutoCleanupEnabled
                    ? "Nothing is eligible to clean — what's left is pinned, still seeding, or rare"
                    : "Automatic cleanup is off, so nothing was removed",
            ]
        )
        onStorageBudgetPressure?(overBy)
    }

    // MARK: - Resolving timeouts

    private func watchResolveTimeouts() {
        for (id, snapshot) in library.snapshots {
            guard case .resolving = snapshot.state else { continue }
            guard -snapshot.addedAt.timeIntervalSinceNow > Self.resolveTimeout else { continue }
            guard resolveTimeoutsHandled.insert(id).inserted else { continue }

            // Remove from the library (which also removes from the engine and
            // drops the row) so the dead magnet can't linger in the UI.
            Task {
                await self.library.remove([id], deleteFiles: false)
            }
            log(
                .magnetTimedOut,
                torrentID: id,
                name: snapshot.name,
                reasons: [
                    "No peers shared the file details within two minutes",
                    "The magnet link may be dead — you can retry it",
                ]
            )
            onMagnetTimedOut?(snapshot.name)
        }
    }

    // MARK: - Decisions

    private func log(
        _ kind: DecisionRecord.Kind,
        torrentID: TorrentID?,
        name: String?,
        reasons: [String]
    ) {
        let record = DecisionRecord(
            kind: kind,
            torrentID: torrentID,
            torrentName: name,
            date: Date(),
            reasons: reasons
        )
        try? database.recordDecision(record)
    }
}
