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
        static let seedPolicy = "seed.policy"
        static let storageLimitGB = "storage.limit.gb"
        static let autoCleanup = "storage.autoCleanup"
        static let notchEnabled = "notch.enabled"
        static let pauseOnBattery = "power.pauseOnBattery"
        static let limitOnBattery = "power.limitOnBattery"
        static let preventSleepWhileDownloading = "power.preventSleepWhileDownloading"
        static let notifyCompleted = "notifications.completed"
        static let notifyFailed = "notifications.failed"
        static let notifyBudget = "notifications.budget"
        static let launchAtLogin = "general.launchAtLogin"
    }

    private let database: AppDatabase

    @Published var downloadsFolder: URL {
        didSet { persist(downloadsFolder.absoluteString, forKey: Keys.downloadsFolder) }
    }
    @Published var defaultSeedPolicy: SeedPolicy {
        didSet { persist(policyKey(defaultSeedPolicy), forKey: Keys.seedPolicy) }
    }
    /// nil means unlimited.
    @Published var storageLimitBytes: Int64? {
        didSet { persist(storageLimitBytes.map(String.init) ?? "", forKey: Keys.storageLimitGB) }
    }
    @Published var isAutoCleanupEnabled: Bool {
        didSet { persist(isAutoCleanupEnabled, forKey: Keys.autoCleanup) }
    }
    @Published var isNotchEnabled: Bool {
        didSet { persist(isNotchEnabled, forKey: Keys.notchEnabled) }
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

    init(database: AppDatabase) {
        self.database = database

        let defaults = database.allSettings()
        func value(_ key: String) -> String? { defaults[key] }

        let documents = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.downloadsFolder =
            value(Keys.downloadsFolder).flatMap(URL.init(string:)) ?? documents.appendingPathComponent("Current")

        self.defaultSeedPolicy = Self.policy(fromKey: value(Keys.seedPolicy))
        let storedLimit = Int64(value(Keys.storageLimitGB) ?? "")
        self.storageLimitBytes = storedLimit.map { $0 * 1_000_000_000 }
        self.isAutoCleanupEnabled = value(Keys.autoCleanup).map({ $0 == "1" }) ?? false
        self.isNotchEnabled = value(Keys.notchEnabled).map({ $0 == "1" }) ?? true
        self.pauseDownloadsOnBattery = value(Keys.pauseOnBattery).map({ $0 == "1" }) ?? false
        self.limitSpeedsOnBattery = value(Keys.limitOnBattery).map({ $0 == "1" }) ?? false
        self.preventSleepWhileDownloading = value(Keys.preventSleepWhileDownloading).map({ $0 == "1" }) ?? false
        self.notifyOnCompletion = value(Keys.notifyCompleted).map({ $0 == "1" }) ?? true
        self.notifyOnFailure = value(Keys.notifyFailed).map({ $0 == "1" }) ?? true
        self.notifyOnBudgetPressure = value(Keys.notifyBudget).map({ $0 == "1" }) ?? true
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

    nonisolated private static func policy(fromKey raw: String?) -> SeedPolicy {
        switch raw {
        case "helpful": return .helpful
        case "archive": return .archive
        case "temporary": return .temporary
        case "custom": return .custom(SeedGoal(targetRatio: 2.0, minimumSeedSeconds: 48 * 3600))
        default: return .balanced
        }
    }

    nonisolated private func policyKey(_ policy: SeedPolicy) -> String {
        switch policy {
        case .balanced: return "balanced"
        case .helpful: return "helpful"
        case .archive: return "archive"
        case .temporary: return "temporary"
        case .custom: return "custom"
        }
    }
}
