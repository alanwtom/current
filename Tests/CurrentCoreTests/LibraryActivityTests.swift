import XCTest
@testable import CurrentCore

final class LibraryActivityTests: XCTestCase {

    private func snapshot(
        _ id: String,
        state: TorrentState,
        down: Double = 0,
        up: Double = 0
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(id),
            name: id,
            state: state,
            progress: state.isComplete ? 1 : 0.4,
            totalBytes: 1_000,
            downloadedBytes: 400,
            uploadedBytes: 0,
            downloadRate: down,
            uploadRate: up,
            swarm: SwarmSummary(connectedSeeds: 5, connectedPeers: 5, knownSeeds: 5),
            activeSeedSeconds: 0
        )
    }

    func testEmptyLibraryHasNothingToSay() {
        XCTAssertNil(LibraryActivity.summarize([]))
    }

    func testCountsCompletedAndSeedingAsDone() {
        let activity = LibraryActivity.summarize([
            snapshot("a", state: .completed),
            snapshot("b", state: .seeding),
            snapshot("c", state: .downloading),
        ])
        XCTAssertEqual(activity?.done, 2)
        XCTAssertEqual(activity?.total, 3)
        XCTAssertEqual(activity?.isFinished, false)
    }

    func testRatesAreSummedAcrossTheLibrary() {
        let activity = LibraryActivity.summarize([
            snapshot("a", state: .downloading, down: 100, up: 10),
            snapshot("b", state: .downloading, down: 250, up: 5),
        ])
        XCTAssertEqual(activity?.downloadRate, 350)
        XCTAssertEqual(activity?.uploadRate, 15)
    }

    func testDownloadingOutranksSeeding() {
        let activity = LibraryActivity.summarize([
            snapshot("a", state: .seeding),
            snapshot("b", state: .downloading),
        ])
        XCTAssertEqual(activity?.dominant, .downloading)
    }

    func testFailureOutranksEverything() {
        let failure = EngineFailure(kind: .diskFull, technicalMessage: "no space")
        let activity = LibraryActivity.summarize([
            snapshot("a", state: .downloading, down: 500),
            snapshot("b", state: .seeding),
            snapshot("c", state: .failed(failure)),
        ])
        XCTAssertEqual(activity?.dominant, .failed)
    }

    func testFinishedLibraryReportsComplete() {
        let activity = LibraryActivity.summarize([
            snapshot("a", state: .completed),
            snapshot("b", state: .completed),
        ])
        XCTAssertEqual(activity?.dominant, .complete)
        XCTAssertEqual(activity?.isFinished, true)
    }

    /// While seeding the interesting number is what's going out, not what's
    /// coming in — the menu bar shows one rate and it should be the right one.
    func testHeadlineRateFollowsTheDominantState() {
        let seeding = LibraryActivity.summarize([
            snapshot("a", state: .seeding, down: 3, up: 900),
        ])
        XCTAssertEqual(seeding?.headlineRate, 900)

        let downloading = LibraryActivity.summarize([
            snapshot("a", state: .downloading, down: 700, up: 40),
        ])
        XCTAssertEqual(downloading?.headlineRate, 700)
    }
}
