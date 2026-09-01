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

    /// Torrents this coordinator paused automatically; resumed when conditions clear.
    private var batteryPaused = Set<TorrentID>()
    private var seedingStoppedLogged = Set<TorrentID>()
    private var cleanupProposedLogged = Set<TorrentID>()
    /// Magnets whose resolve timeout has already been handled, so a stale
    /// row can't re-trigger removal + logging on every tick.
    private var resolveTimeoutsHandled = Set<TorrentID>()

    private var timer: Timer?
    static let tickInterval: TimeInterval = 15
    static let resolveTimeout: TimeInterval = 120

    init(
        library: LibraryStore,
        settings: SettingsStore,
        database: AppDatabase,
        power: PowerMonitor
    ) {
        self.library = library
        self.settings = settings
        self.database = database
        self.power = power

        timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    func tick() {
        enforceSeedGoals()
        enforcePowerPolicy()
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
