import XCTest
@testable import CurrentApp

/// The update question is the one place the app's privacy claim and its
/// security needs pull against each other, so the defaults are pinned.
@MainActor
final class UpdateSettingsTests: XCTestCase {

    private func freshStore() throws -> SettingsStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("current-updates-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
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

    /// Both answers have to survive a relaunch, and declining has to be
    /// remembered as an answer — otherwise the card comes back every launch.
    func testTheAnswerSurvivesARelaunch() throws {
        for accepts in [false, true] {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("current-updates-\(UUID().uuidString).sqlite")
            addTeardownBlock { try? FileManager.default.removeItem(at: url) }
            let database = AppDatabase(url: url)

            let first = SettingsStore(database: database)
            first.checksForUpdatesAutomatically = accepts
            first.hasAnsweredUpdateQuestion = true
            first.flushPendingWrites()

            let relaunched = SettingsStore(database: AppDatabase(url: url))
            XCTAssertTrue(relaunched.hasAnsweredUpdateQuestion)
            XCTAssertEqual(relaunched.checksForUpdatesAutomatically, accepts)
        }
    }
}
