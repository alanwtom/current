import XCTest
@testable import CurrentApp

/// The update question is the one place the app's privacy claim and its
/// security needs pull against each other, so the defaults are pinned.
@MainActor
final class UpdateSettingsTests: XCTestCase {

    private func freshStore() throws -> SettingsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("current-updates-\(UUID().uuidString).sqlite")
        return SettingsStore(database: AppDatabase(url: url))
    }

    /// A brand-new install must not check for updates, and must know it has
    /// not asked yet. If this ever defaults to true, the app makes a network
    /// call the user never agreed to and the download page starts lying.
    func testAFreshInstallHasNotAskedAndDoesNotCheck() throws {
        let settings = try freshStore()
        XCTAssertFalse(settings.hasAnsweredUpdateQuestion, "a fresh install has not asked yet")
        XCTAssertFalse(settings.checksForUpdatesAutomatically, "a fresh install must not check")
    }

    /// Declining has to be remembered as a decision, not left looking like a
    /// fresh install — otherwise the card comes back every launch.
    func testDecliningIsRememberedAsAnAnswer() throws {
        let settings = try freshStore()
        settings.checksForUpdatesAutomatically = false
        settings.hasAnsweredUpdateQuestion = true

        XCTAssertTrue(settings.hasAnsweredUpdateQuestion)
        XCTAssertFalse(settings.checksForUpdatesAutomatically)
    }

    /// Accepting persists too, so the answer survives a relaunch.
    func testAcceptingPersists() throws {
        let settings = try freshStore()
        settings.checksForUpdatesAutomatically = true
        settings.hasAnsweredUpdateQuestion = true

        XCTAssertTrue(settings.checksForUpdatesAutomatically)
        XCTAssertTrue(settings.hasAnsweredUpdateQuestion)
    }
}
