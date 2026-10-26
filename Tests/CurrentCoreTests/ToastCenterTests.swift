import XCTest
@testable import CurrentApp

@MainActor
final class ToastCenterTests: XCTestCase {
    func testAPausedToastWaitsForTheReaderThenResumesItsTimer() async throws {
        let center = ToastCenter()
        center.show(.info, title: "Read this")
        let presented = try XCTUnwrap(center.toasts.first)
        // Both pointer hover and keyboard focus use this pause path.
        center.pauseHover(presented.id)
        try await Task.sleep(for: .seconds(ToastCenter.displayDuration + 0.5))
        XCTAssertEqual(center.toasts.map(\.id), [presented.id])

        center.resumeHover(presented.id)
        let expiry = ContinuousClock.now + .seconds(ToastCenter.displayDuration + 2)
        while !center.toasts.isEmpty, ContinuousClock.now < expiry {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(center.toasts.isEmpty)
    }

    func testDismissalCancelsTheLifetimeTask() throws {
        let center = ToastCenter()
        center.show(.info, title: "Read this")
        let presented = try XCTUnwrap(center.toasts.first)
        center.pauseHover(presented.id)
        center.dismiss(presented.id)
        XCTAssertTrue(center.toasts.isEmpty)
        XCTAssertTrue(presented.dismissTask.isCancelled)
    }
}
