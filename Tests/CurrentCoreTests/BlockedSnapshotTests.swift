import XCTest
@testable import CurrentCore

/// What a torrent says while the app is blocked from the network.
///
/// The rule being pinned down here is the one that made the binding look
/// broken from the outside: a confined engine with no connection moves no
/// bytes, so anything on screen claiming otherwise — a rate, an ETA, the word
/// "Downloading" — is the app lying about the one thing this feature exists to
/// guarantee.
final class BlockedSnapshotTests: XCTestCase {

    private func snapshot(
        state: TorrentState,
        down: Double = 2_000_000,
        up: Double = 500_000,
        eta: TimeInterval? = 120
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID("t"),
            name: "t",
            state: state,
            progress: state.isComplete ? 1 : 0.4,
            totalBytes: 1_000,
            downloadedBytes: 400,
            uploadedBytes: 100,
            downloadRate: down,
            uploadRate: up,
            etaSeconds: eta,
            swarm: SwarmSummary(connectedSeeds: 5, connectedPeers: 5, knownSeeds: 5),
            activeSeedSeconds: 0
        )
    }

    func testRatesGoToZeroWhateverTheState() {
        let states: [TorrentState] = [
            .resolving, .downloading, .seeding, .checking,
            .completed, .paused(.user),
            .failed(EngineFailure(kind: .unknown, technicalMessage: "x")),
        ]
        for state in states {
            let blocked = snapshot(state: state).blockedByNetwork()
            XCTAssertEqual(blocked.downloadRate, 0, "download rate survived in \(state)")
            XCTAssertEqual(blocked.uploadRate, 0, "upload rate survived in \(state)")
        }
    }

    func testActiveStatesBecomeStoppedForTheRightReason() {
        for state in [TorrentState.resolving, .downloading, .seeding, .checking] {
            let blocked = snapshot(state: state).blockedByNetwork()
            XCTAssertEqual(blocked.state, .paused(.connectionUnavailable))
            XCTAssertNil(blocked.etaSeconds, "an ETA implies progress, and nothing is progressing")
        }
    }

    /// A finished download is a fact, not an activity. Rewriting it would throw
    /// away a real outcome and re-open a torrent the user is done with.
    func testFinishedAndFailedKeepTheirOutcome() {
        XCTAssertEqual(snapshot(state: .completed).blockedByNetwork().state, .completed)

        let failure = EngineFailure(kind: .diskFull, technicalMessage: "x")
        XCTAssertEqual(snapshot(state: .failed(failure)).blockedByNetwork().state, .failed(failure))
    }

    /// The connection is not why this one is stopped, and saying it is would
    /// send someone off to fix their VPN over a torrent they paused themselves.
    func testAUserPauseStillSaysItWasTheUser() {
        XCTAssertEqual(snapshot(state: .paused(.user)).blockedByNetwork().state, .paused(.user))
    }

    /// Progress is untouched on purpose — it is the one number that is still
    /// true, and zeroing it would make a half-finished download look lost.
    func testProgressIsLeftAlone() {
        let blocked = snapshot(state: .downloading).blockedByNetwork()
        XCTAssertEqual(blocked.progress, 0.4)
        XCTAssertEqual(blocked.downloadedBytes, 400)
    }
}
