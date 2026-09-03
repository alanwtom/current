import XCTest
import CurrentCore
@testable import CurrentApp

/// Regression cover for a crash-on-launch found by sweeping the UI.
///
/// `storageLimitBytes` persisted a **byte count**, and `init` read it back and
/// multiplied it by a billion as though it were gigabytes. Switching the storage
/// budget on wrote 100,000,000,000; the next launch computed 1e20, overflowed
/// `Int64`, and trapped — inside `SettingsStore.init`, which runs before there
/// is any window. The app then crashed on every launch, and nothing the user
/// could do from inside it would help, because it never got far enough to show
/// anything.
///
/// These tests fail loudly rather than politely if the round trip breaks again:
/// the first one would trap the whole test process on the old code.
@MainActor
final class SettingsStoreTests: XCTestCase {

    private func makeDatabase() -> AppDatabase {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-settings-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return AppDatabase(url: url)
    }

    /// The one that mattered: set a budget, reopen, get the same budget.
    func testStorageLimitSurvivesRelaunchUnchanged() async throws {
        let database = makeDatabase()
        let hundredGB: Int64 = 100_000_000_000

        let first = SettingsStore(database: database)
        first.storageLimitBytes = hundredGB

        // The write is detached; give it a moment to land before reopening.
        try await Task.sleep(for: .milliseconds(250))

        let second = SettingsStore(database: database)
        XCTAssertEqual(second.storageLimitBytes, hundredGB)
    }

    func testNoStorageLimitStaysNil() async throws {
        let database = makeDatabase()
        let store = SettingsStore(database: database)
        XCTAssertNil(store.storageLimitBytes)
    }

    // MARK: - Sanitising

    func testSanitizerAcceptsAPlausibleBudget() {
        XCTAssertEqual(SettingsStore.sanitizedLimit("100000000000"), 100_000_000_000)
    }

    /// Junk in the database must not reach the arithmetic that crashed.
    func testSanitizerRejectsNonsense() {
        XCTAssertNil(SettingsStore.sanitizedLimit(nil))
        XCTAssertNil(SettingsStore.sanitizedLimit(""))
        XCTAssertNil(SettingsStore.sanitizedLimit("not a number"))
        XCTAssertNil(SettingsStore.sanitizedLimit("-5"))
        XCTAssertNil(SettingsStore.sanitizedLimit("0"))
    }

    /// The shape of the old bug's output — a value a billion times too large.
    /// It has to be refused rather than carried forward.
    func testSanitizerRejectsAnImpossiblyLargeBudget() {
        XCTAssertNil(SettingsStore.sanitizedLimit("\(Int64.max)"))
        XCTAssertNil(SettingsStore.sanitizedLimit("100000000000000000"))
    }
}
