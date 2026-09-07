import XCTest
@testable import CurrentCore

/// Cover for the app's entire crash-reporting story, which is one menu item
/// and no telemetry.
///
/// Two things here are worth a test rather than a look. The crash window is
/// the reason the feature isn't actively harmful: attach a six-month-old crash
/// to a report about a mis-drawn row and the reading of it goes somewhere with
/// nothing to do with the bug. And the URL encoding has one specific trap —
/// GitHub reads `+` in a query as a space — which is invisible until a report
/// arrives with its body mangled.
final class ProblemReportTests: XCTestCase {

    private let environment = ProblemReport.Environment(
        version: "1.1.1",
        build: "412",
        system: "Version 26.0 (Build 25A354)",
        model: "Mac15,3",
        isSimulating: false
    )

    private func report(_ name: String, daysAgo: Double) -> ProblemReport.CrashReport {
        ProblemReport.CrashReport(name: name, modified: Date(timeIntervalSince1970: 1_000_000)
            .addingTimeInterval(-daysAgo * 24 * 60 * 60))
    }

    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }

    // MARK: - Which crash report

    func testPicksTheNewestReport() {
        let found = ProblemReport.newestCrashReport(
            among: [
                report("Current-2026-09-01-120000.ips", daysAgo: 6),
                report("Current-2026-09-05-120000.ips", daysAgo: 2),
                report("Current-2026-09-03-120000.ips", daysAgo: 4),
            ],
            now: now
        )
        XCTAssertEqual(found?.name, "Current-2026-09-05-120000.ips")
    }

    /// The point of the window. An old crash is not this bug.
    func testIgnoresReportsOlderThanTheWindow() {
        let found = ProblemReport.newestCrashReport(
            among: [report("Current-2026-01-01-120000.ips", daysAgo: 200)],
            now: now
        )
        XCTAssertNil(found)
    }

    func testKeepsAReportRightAtTheEdgeOfTheWindow() {
        let found = ProblemReport.newestCrashReport(
            among: [report("Current-edge.ips", daysAgo: 14)],
            now: now
        )
        XCTAssertEqual(found?.name, "Current-edge.ips")
    }

    /// Another app with "Current" in its name is not ours, and neither is a
    /// spindump or a hang report sitting in the same folder.
    func testIgnoresOtherAppsAndOtherKindsOfReport() {
        let found = ProblemReport.newestCrashReport(
            among: [
                report("CurrentlyOther-2026-09-05.ips", daysAgo: 1),
                report("Safari-2026-09-05.ips", daysAgo: 1),
                report("Current-2026-09-05-120000.diag", daysAgo: 1),
                report("Current-2026-09-05-120000.spin", daysAgo: 1),
            ],
            now: now
        )
        XCTAssertNil(found)
    }

    func testNoReportsAtAll() {
        XCTAssertNil(ProblemReport.newestCrashReport(among: [], now: now))
    }

    /// A clock that has been moved backwards, which is a real thing that
    /// happens to laptops. The report is still the newest thing on disk and
    /// still the one the person is looking at.
    func testKeepsAReportDatedInTheFuture() {
        let found = ProblemReport.newestCrashReport(
            among: [report("Current-future.ips", daysAgo: -3)],
            now: now
        )
        XCTAssertEqual(found?.name, "Current-future.ips")
    }

    // MARK: - What the report says

    func testTheBodyCarriesTheFactsWeWouldOtherwiseAskFor() {
        let text = ProblemReport.body(environment: environment, crashReport: nil)
        XCTAssertTrue(text.contains("Version 26.0 (Build 25A354)"))
        XCTAssertTrue(text.contains("Mac15,3"))
        // Version *and* build: two builds of 1.1.1 are dozens of commits apart.
        XCTAssertTrue(text.contains("1.1.1 (412)"))
        XCTAssertTrue(text.contains("**What happened?**"))
    }

    /// A report filed from a demo build describes a simulation. Worth knowing
    /// before spending an hour on it.
    func testSimulatedBuildsSaySo() {
        var simulated = environment
        simulated = ProblemReport.Environment(
            version: simulated.version, build: simulated.build,
            system: simulated.system, model: simulated.model, isSimulating: true
        )
        XCTAssertTrue(ProblemReport.body(environment: simulated, crashReport: nil)
            .contains("-simulate"))
    }

    /// Named, not described — the whole reason this beats "attach your crash
    /// log".
    func testTheCrashReportIsNamedInFull() {
        let text = ProblemReport.body(
            environment: environment,
            crashReport: "~/Library/Logs/DiagnosticReports/Current-2026-09-05-120000.ips"
        )
        XCTAssertTrue(text.contains("Current-2026-09-05-120000.ips"))
        XCTAssertTrue(text.contains("Drag it"))
    }

    func testNoCrashReportMeansNoInstructionToAttachOne() {
        let text = ProblemReport.body(environment: environment, crashReport: nil)
        XCTAssertFalse(text.contains("DiagnosticReports"))
        XCTAssertFalse(text.contains("Drag it"))
    }

    // MARK: - The URL

    func testTheURLIsWellFormedAndCarriesTheBody() throws {
        let url = try XCTUnwrap(ProblemReport.issueURL(
            repository: "alanwtom/current",
            environment: environment,
            crashReport: nil
        ))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/alanwtom/current/issues/new")

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "labels" }?.value, "bug")
        let body = try XCTUnwrap(query.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("Mac15,3"))
        XCTAssertTrue(body.contains("\n"), "the body should survive as multi-line Markdown")
    }

    /// The trap. GitHub reads a `+` in a query as a space, so a `+` left
    /// unescaped arrives as a hole in the report — and nothing about the URL
    /// looks wrong beforehand.
    func testPlusSignsAreEscapedRatherThanBecomingSpaces() throws {
        let plus = ProblemReport.Environment(
            version: "1.1.1+beta", build: "412",
            system: "Version 26.0 (Build 25A354)", model: "Mac15,3", isSimulating: false
        )
        let url = try XCTUnwrap(ProblemReport.issueURL(
            repository: "alanwtom/current", environment: plus, crashReport: nil
        ))
        XCTAssertTrue(url.absoluteString.contains("1.1.1%2Bbeta"))
        XCTAssertFalse(url.absoluteString.contains("1.1.1+beta"))

        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(query.first { $0.name == "body" }?.value)
        XCTAssertTrue(body.contains("1.1.1+beta"))
    }

    /// Markdown, an em dash and a path all go in the query. Any of them
    /// breaking the URL would be silent.
    func testTheWholeBodySurvivesEncoding() throws {
        let url = try XCTUnwrap(ProblemReport.issueURL(
            repository: "alanwtom/current",
            environment: environment,
            crashReport: "~/Library/Logs/DiagnosticReports/Current-2026-09-05-120000.ips"
        ))
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let body = try XCTUnwrap(query.first { $0.name == "body" }?.value)
        XCTAssertEqual(
            body,
            ProblemReport.body(
                environment: environment,
                crashReport: "~/Library/Logs/DiagnosticReports/Current-2026-09-05-120000.ips"
            )
        )
    }
}
