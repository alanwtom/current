import XCTest
import CurrentCore
@testable import CurrentApp

/// The "which files, and where?" card belongs to exactly one torrent.
///
/// Every rule here is one the card broke: it took whichever torrent resolved
/// first, a second magnet overwrote it mid-question, and any download
/// finishing anywhere in the library replaced it with a "done" badge. Each
/// time, the torrent it had been asking about was left behind — and before
/// torrents were added held, left behind meant downloading every file.
@MainActor
final class MagnetFlowTests: XCTestCase {

    private let clicked = TorrentID("clicked")
    private let other = TorrentID("other")

    private func resolving() -> MagnetFlowCenter {
        let flow = MagnetFlowCenter()
        XCTAssertTrue(flow.beginResolving(nameHint: "Clicked"))
        flow.awaiting(clicked)
        return flow
    }

    func testCancelledAddCannotClaimANewerQuestion() {
        let flow = resolving()
        let oldRequest = flow.requestID
        flow.dismiss()
        XCTAssertTrue(flow.beginResolving(nameHint: "New"))
        XCTAssertFalse(flow.ownsRequest(oldRequest))
        XCTAssertTrue(flow.ownsRequest(flow.requestID))
        XCTAssertFalse(flow.ownsRequest(nil))
    }

    func testCancelInvalidatesAPendingConfirmationBeforeRemoval() throws {
        let flow = resolving()
        XCTAssertTrue(flow.metadataArrived(id: clicked))
        let request = try XCTUnwrap(flow.beginConfirmation())

        XCTAssertEqual(flow.cancelSelection(), clicked)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertFalse(flow.ownsRequest(request), "a pending engine call must not resume this torrent")
        XCTAssertNil(flow.beginConfirmation())

        XCTAssertTrue(flow.beginResolving(nameHint: "Next"))
        let nextRequest = flow.requestID
        flow.finishConfirmation(request)
        XCTAssertTrue(flow.ownsRequest(nextRequest), "old completion must leave the new question alone")
    }

    func testOnlyOneConfirmationCanRunAndFailureAllowsRetry() throws {
        let flow = resolving()
        XCTAssertTrue(flow.metadataArrived(id: clicked))
        let request = try XCTUnwrap(flow.beginConfirmation())
        XCTAssertNil(flow.beginConfirmation(), "double-clicking Download must not start a second move")
        flow.finishConfirmation(request)
        XCTAssertEqual(flow.beginConfirmation(), request, "a failed folder choice must allow another try")
    }

    func testCancelWhileAddIsPendingPreventsItClaimingALaterQuestion() {
        let flow = MagnetFlowCenter()
        XCTAssertTrue(flow.beginResolving(nameHint: "Slow"))
        let request = flow.requestID
        XCTAssertNil(flow.cancelSelection(), "the add has not returned an id yet")
        XCTAssertFalse(flow.ownsRequest(request))
        XCTAssertTrue(flow.beginResolving(nameHint: "New"))
        XCTAssertFalse(flow.ownsRequest(request))
    }

    func testNewCompletionInvalidatesOlderCompletionTimer() {
        let flow = MagnetFlowCenter()
        flow.downloadCompleted(name: "First")
        let oldRequest = flow.requestID
        flow.downloadCompleted(name: "Second")
        XCTAssertFalse(flow.ownsRequest(oldRequest))
        XCTAssertTrue(flow.ownsRequest(flow.requestID))
        XCTAssertEqual(flow.stage, .completed(name: "Second"))
    }

    func testOnlyTheAwaitedTorrentsMetadataMovesTheCardOn() {
        let flow = resolving()
        // A restored torrent, or a second magnet, resolving first.
        XCTAssertFalse(flow.metadataArrived(id: other))
        guard case .resolving = flow.stage else { return XCTFail("moved on for the wrong torrent") }

        XCTAssertTrue(flow.metadataArrived(id: clicked))
        XCTAssertEqual(flow.stage, .selecting(clicked))
    }

    func testASecondDownloadDoesNotTakeOverABusyCard() {
        let flow = resolving()
        XCTAssertFalse(flow.beginResolving(nameHint: "Second"), "the caller must add it held instead")
        XCTAssertEqual(flow.awaitedID, clicked)

        _ = flow.metadataArrived(id: clicked)
        XCTAssertFalse(flow.beginResolving(nameHint: "Third"))
        XCTAssertEqual(flow.stage, .selecting(clicked))
    }

    func testAnotherDownloadFinishingDoesNotReplaceTheQuestion() {
        let flow = resolving()
        _ = flow.metadataArrived(id: clicked)

        flow.downloadCompleted(name: "Something else")

        XCTAssertEqual(flow.stage, .selecting(clicked), "the card was still waiting for an answer")
    }

    func testACompletionIsCelebratedWhenNothingIsBeingAsked() {
        let flow = MagnetFlowCenter()
        flow.downloadCompleted(name: "Done")
        XCTAssertEqual(flow.stage, .completed(name: "Done"))
    }

    func testTheCardGoesWhenItsTorrentDoes() {
        let flow = resolving()
        flow.torrentRemoved(other)
        XCTAssertNotEqual(flow.stage, .idle, "someone else's torrent going is no reason to close")

        flow.torrentRemoved(clicked)
        XCTAssertEqual(flow.stage, .idle)
        XCTAssertNil(flow.awaitedID)
    }

    func testAFinishedHandoffFreesTheCardForTheNextDownload() {
        let flow = resolving()
        _ = flow.metadataArrived(id: clicked)
        flow.confirmSelection()
        flow.handoffFinished()

        XCTAssertEqual(flow.stage, .idle)
        XCTAssertTrue(flow.beginResolving(nameHint: "Next"))
    }
}
