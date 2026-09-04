import Foundation
import SwiftUI
import Combine
import CurrentCore

/// User-facing settings. Persisted through `AppDatabase` so they survive
/// reinstalls of the sandbox container and are inspectable.
@MainActor
final class SettingsStore: ObservableObject {

    enum Keys {
        static let downloadsFolder = "downloads.folder"
        static let askForLocation = "downloads.askForLocation"
        static let seedPolicy = "seed.policy"
        /// Holds a byte count, despite the name. The key string is kept as-is so
        /// existing installs don't lose their budget; only the constant is
        /// honest about it.
        static let storageLimit = "storage.limit.gb"
        static let autoCleanup = "storage.autoCleanup"
        static let pauseOnBattery = "power.pauseOnBattery"
        static let limitOnBattery = "power.limitOnBattery"
        static let preventSleepWhileDownloading = "power.preventSleepWhileDownloading"
        static let notifyCompleted = "notifications.completed"
        static let notifyFailed = "notifications.failed"
        static let notifyBudget = "notifications.budget"
        static let launchAtLogin = "general.launchAtLogin"
        static let appearance = "general.appearance"
        // Bandwidth. Stored in bytes/second; 0 means unlimited.
        static let normalDown = "bandwidth.normal.down"
        static let normalUp = "bandwidth.normal.up"
        static let reducedDown = "bandwidth.reduced.down"
        static let reducedUp = "bandwidth.reduced.up"
        static let reducedForced = "bandwidth.reduced.forced"
        // Queue and connections.
        static let maxConnections = "network.maxConnections"
        static let maxUploadSlots = "network.maxUploadSlots"
        static let maxActiveDownloads = "queue.maxActiveDownloads"
        static let maxActiveSeeds = "queue.maxActiveSeeds"
        // Network.
        static let listenPort = "network.listenPort"
        static let dhtEnabled = "network.dht"
        static let lsdEnabled = "network.lsd"
        static let portMappingEnabled = "network.portMapping"
        static let encryption = "network.encryption"
    }

    private let database: AppDatabase

    @Published var downloadsFolder: URL {
        didSet { persist(downloadsFolder.absoluteString, forKey: Keys.downloadsFolder) }
    }
    /// Whether each download gets to choose its own folder.
    ///
    /// On, the confirm card carries a destination you can change. Ticking
    /// "Remember this location" there turns this off and makes that folder the
    /// default — which is the only way it ever gets switched off from inside the
    /// flow, so this switch is how you ask for the question back.
    @Published var asksForDownloadLocation: Bool {
        didSet { persist(asksForDownloadLocation, forKey: Keys.askForLocation) }
    }
    @Published var defaultSeedPolicy: SeedPolicy {
        didSet { persist(policyKey(defaultSeedPolicy), forKey: Keys.seedPolicy) }
    }
    /// nil means unlimited.
    @Published var storageLimitBytes: Int64? {
        didSet { persist(storageLimitBytes.map(String.init) ?? "", forKey: Keys.storageLimit) }
    }
    @Published var isAutoCleanupEnabled: Bool {
        didSet { persist(isAutoCleanupEnabled, forKey: Keys.autoCleanup) }
    }
    /// Light, dark, or follow the Mac. Applied immediately rather than on next
    /// launch — the Appearance pane is the one place where the setting *is* the
    /// preview, so it has to take effect as you click it.
    @Published var appearance: AppearanceMode {
        didSet {
            guard appearance != oldValue else { return }
            AppearanceApplier.apply(appearance)
            persist(appearance.rawValue, forKey: Keys.appearance)
        }
    }
    @Published var pauseDownloadsOnBattery: Bool {
        didSet { persist(pauseDownloadsOnBattery, forKey: Keys.pauseOnBattery) }
    }
    @Published var limitSpeedsOnBattery: Bool {
        didSet { persist(limitSpeedsOnBattery, forKey: Keys.limitOnBattery) }
    }
    @Published var preventSleepWhileDownloading: Bool {
        didSet { persist(preventSleepWhileDownloading, forKey: Keys.preventSleepWhileDownloading) }
    }
    @Published var notifyOnCompletion: Bool {
        didSet { persist(notifyOnCompletion, forKey: Keys.notifyCompleted) }
    }
    @Published var notifyOnFailure: Bool {
        didSet { persist(notifyOnFailure, forKey: Keys.notifyFailed) }
    }
    @Published var notifyOnBudgetPressure: Bool {
        didSet { persist(notifyOnBudgetPressure, forKey: Keys.notifyBudget) }
    }

    // MARK: - Bandwidth, queue and network
    //
    // Every one of these ends up in `engineConfiguration`, which the app pushes
    // to the engine whenever it changes. A setting that isn't reachable from
    // there is a setting that does nothing — which is exactly what
    // `limitSpeedsOnBattery` was before this existed.

    @Published var normalDownloadLimit: Int {
        didSet { persist(String(normalDownloadLimit), forKey: Keys.normalDown) }
    }
    @Published var normalUploadLimit: Int {
        didSet { persist(String(normalUploadLimit), forKey: Keys.normalUp) }
    }
    @Published var reducedDownloadLimit: Int {
        didSet { persist(String(reducedDownloadLimit), forKey: Keys.reducedDown) }
    }
    @Published var reducedUploadLimit: Int {
        didSet { persist(String(reducedUploadLimit), forKey: Keys.reducedUp) }
    }
    @Published var isReducedSpeedForced: Bool {
        didSet { persist(isReducedSpeedForced, forKey: Keys.reducedForced) }
    }
    @Published var maxConnections: Int {
        didSet { persist(String(maxConnections), forKey: Keys.maxConnections) }
    }
    @Published var maxUploadSlots: Int {
        didSet { persist(String(maxUploadSlots), forKey: Keys.maxUploadSlots) }
    }
    @Published var maxActiveDownloads: Int {
        didSet { persist(String(maxActiveDownloads), forKey: Keys.maxActiveDownloads) }
    }
    @Published var maxActiveSeeds: Int {
        didSet { persist(String(maxActiveSeeds), forKey: Keys.maxActiveSeeds) }
    }
    @Published var listenPort: Int {
        didSet { persist(String(listenPort), forKey: Keys.listenPort) }
    }
    @Published var isDHTEnabled: Bool {
        didSet { persist(isDHTEnabled, forKey: Keys.dhtEnabled) }
    }
    @Published var isLocalDiscoveryEnabled: Bool {
        didSet { persist(isLocalDiscoveryEnabled, forKey: Keys.lsdEnabled) }
    }
    @Published var isPortMappingEnabled: Bool {
        didSet { persist(isPortMappingEnabled, forKey: Keys.portMappingEnabled) }
    }
    @Published var encryption: EncryptionPolicy {
        didSet { persist(encryption.rawValue, forKey: Keys.encryption) }
    }

    /// How the speed settings resolve, given the power source.
    var bandwidthPolicy: BandwidthPolicy {
        BandwidthPolicy(
            normal: RateLimits(download: normalDownloadLimit, upload: normalUploadLimit),
            reduced: RateLimits(download: reducedDownloadLimit, upload: reducedUploadLimit),
            isReducedForced: isReducedSpeedForced,
            reduceOnBattery: limitSpeedsOnBattery
        )
    }

    /// The single value handed to the engine. `onBattery` decides which set of
    /// speed limits is in force.
    func engineConfiguration(onBattery: Bool) -> EngineConfiguration {
        EngineConfiguration(
            rateLimits: bandwidthPolicy.effectiveLimits(onBattery: onBattery),
            maxConnections: maxConnections,
            maxUploadSlots: maxUploadSlots,
            maxActiveDownloads: maxActiveDownloads,
            maxActiveSeeds: maxActiveSeeds,
            listenPort: listenPort,
            isDHTEnabled: isDHTEnabled,
            isLocalDiscoveryEnabled: isLocalDiscoveryEnabled,
            isPortMappingEnabled: isPortMappingEnabled,
            encryption: encryption
        )
    }

    init(database: AppDatabase) {
        self.database = database

        let defaults = database.allSettings()
        func value(_ key: String) -> String? { defaults[key] }

        let documents = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.downloadsFolder =
            value(Keys.downloadsFolder).flatMap(URL.init(string:)) ?? documents.appendingPathComponent("Current")

        // On by default: a download that silently lands somewhere you didn't
        // pick is the thing this setting exists to stop. One tick of "Remember
        // this location" turns it off for good.
        self.asksForDownloadLocation = value(Keys.askForLocation).map({ $0 == "1" }) ?? true
        self.defaultSeedPolicy = Self.policy(fromKey: value(Keys.seedPolicy))
        // Read back as bytes, because bytes are what `didSet` writes.
        //
        // This used to multiply the stored number by a billion, treating it as
        // gigabytes — and it is a byte count. Switching the storage limit on
        // wrote 100,000,000,000; the next launch multiplied that by 1e9, blew
        // past `Int64.max`, and the app trapped on arithmetic overflow *inside
        // its own initialiser*. Every launch after that crashed the same way,
        // with no way out from inside the app. `Self.sanitizedLimit` is the belt
        // and braces: a nonsense value now disables the budget instead of
        // taking the process down.
        self.storageLimitBytes = Self.sanitizedLimit(value(Keys.storageLimit))
        self.isAutoCleanupEnabled = value(Keys.autoCleanup).map({ $0 == "1" }) ?? false
        // System on a fresh install: the app should look like it belongs on the
        // machine before it looks like it has an opinion.
        self.appearance = value(Keys.appearance).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        self.pauseDownloadsOnBattery = value(Keys.pauseOnBattery).map({ $0 == "1" }) ?? false
        self.limitSpeedsOnBattery = value(Keys.limitOnBattery).map({ $0 == "1" }) ?? false
        self.preventSleepWhileDownloading = value(Keys.preventSleepWhileDownloading).map({ $0 == "1" }) ?? false
        self.notifyOnCompletion = value(Keys.notifyCompleted).map({ $0 == "1" }) ?? true
        self.notifyOnFailure = value(Keys.notifyFailed).map({ $0 == "1" }) ?? true
        self.notifyOnBudgetPressure = value(Keys.notifyBudget).map({ $0 == "1" }) ?? true

        func int(_ key: String, default fallback: Int) -> Int {
            value(key).flatMap(Int.init) ?? fallback
        }
        // Unlimited by default: an app that silently throttled you would be
        // worse than one with no limits at all.
        self.normalDownloadLimit = int(Keys.normalDown, default: 0)
        self.normalUploadLimit = int(Keys.normalUp, default: 0)
        // Reduced defaults are deliberately modest — the point is to stay out
        // of the way of whatever else the machine is doing.
        self.reducedDownloadLimit = int(Keys.reducedDown, default: 1_000_000)
        self.reducedUploadLimit = int(Keys.reducedUp, default: 250_000)
        self.isReducedSpeedForced = value(Keys.reducedForced).map({ $0 == "1" }) ?? false
        self.maxConnections = int(Keys.maxConnections, default: 200)
        self.maxUploadSlots = int(Keys.maxUploadSlots, default: 8)
        self.maxActiveDownloads = int(Keys.maxActiveDownloads, default: 5)
        self.maxActiveSeeds = int(Keys.maxActiveSeeds, default: 5)
        self.listenPort = int(Keys.listenPort, default: 6881)
        self.isDHTEnabled = value(Keys.dhtEnabled).map({ $0 == "1" }) ?? true
        self.isLocalDiscoveryEnabled = value(Keys.lsdEnabled).map({ $0 == "1" }) ?? true
        self.isPortMappingEnabled = value(Keys.portMappingEnabled).map({ $0 == "1" }) ?? true
        self.encryption = value(Keys.encryption).flatMap(EncryptionPolicy.init(rawValue:)) ?? .preferred
    }

    var usedStorageBytes: Int64 = 0

    private func persist(_ value: String, forKey key: String) {
        Task.detached(priority: .utility) { [database] in
            try? await database.set(value, forKey: key)
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
        persist(value ? "1" : "0", forKey: key)
    }

    /// A stored storage budget, or `nil` for "no limit".
    ///
    /// Anything absent, unparseable, negative or absurd reads as no limit.
    /// A settings value is not worth crashing over, and this one is read before
    /// there is any UI to complain through.
    nonisolated static func sanitizedLimit(_ raw: String?) -> Int64? {
        guard let raw, !raw.isEmpty, let bytes = Int64(raw), bytes > 0 else { return nil }
        // A petabyte of torrents is not a budget anyone set on purpose.
        return bytes <= 1_000_000_000_000_000 ? bytes : nil
    }

    nonisolated private static func policy(fromKey raw: String?) -> SeedPolicy {
        switch raw {
        case "helpful": return .helpful
        case "archive": return .archive
        case "temporary": return .temporary
        default: return .balanced
        }
    }

    nonisolated private func policyKey(_ policy: SeedPolicy) -> String {
        switch policy {
        case .balanced: return "balanced"
        case .helpful: return "helpful"
        case .archive: return "archive"
        case .temporary: return "temporary"
        }
    }
}
