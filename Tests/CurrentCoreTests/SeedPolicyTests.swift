import XCTest
@testable import CurrentCore

final class SeedPolicyTests: XCTestCase {

    private func snapshot(
        progress: Double = 1,
        uploaded: Int64,
        downloaded: Int64,
        seedSeconds: TimeInterval,
        seeds: Int,
        state: TorrentState = .seeding
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID("test"),
            name: "Test",
            state: state,
            progress: progress,
            totalBytes: 1_000,
            downloadedBytes: downloaded,
            uploadedBytes: uploaded,
            swarm: SwarmSummary(connectedSeeds: seeds, connectedPeers: 5, knownSeeds: seeds),
            activeSeedSeconds: seedSeconds
        )
    }

    func testBalancedStopsOnlyWhenRatioAndTimeMet() {
        let now = Date()

        // Ratio met, time not met.
        var snap = snapshot(uploaded: 1_100, downloaded: 1_000, seedSeconds: 3600, seeds: 20)
        var decision = SeedEvaluator.evaluate(snapshot: snap, policy: .balanced, now: now)
        XCTAssertFalse(decision.shouldStop)
        XCTAssertTrue(decision.reasons[0].contains("Still seeding"))

        // Time met, ratio not met.
        snap = snapshot(uploaded: 400, downloaded: 1_000, seedSeconds: 30 * 3600, seeds: 20)
        decision = SeedEvaluator.evaluate(snapshot: snap, policy: .balanced, now: now)
        XCTAssertFalse(decision.shouldStop)

        // Both met.
        snap = snapshot(uploaded: 1_420, downloaded: 1_000, seedSeconds: 26 * 3600, seeds: 20)
        decision = SeedEvaluator.evaluate(snapshot: snap, policy: .balanced, now: now)
        XCTAssertTrue(decision.shouldStop)
        XCTAssertTrue(decision.goalMet)
        XCTAssertTrue(decision.reasons.contains(where: { $0.contains("Swarm is healthy") }))
    }

    func testHelpfulKeepsRareTorrentsEvenAfterGoal() {
        let snap = snapshot(uploaded: 2_000, downloaded: 1_000, seedSeconds: 30 * 3600, seeds: 2)
        let balanced = SeedEvaluator.evaluate(snapshot: snap, policy: .balanced)
        XCTAssertTrue(balanced.shouldStop)

        let helpful = SeedEvaluator.evaluate(snapshot: snap, policy: .helpful)
        XCTAssertFalse(helpful.shouldStop)
        XCTAssertTrue(helpful.goalMet)
        XCTAssertTrue(helpful.reasons.contains { $0.contains("Helpful mode") })
    }

    func testArchiveNeverStops() {
        let snap = snapshot(uploaded: 9_999, downloaded: 1_000, seedSeconds: 10_000 * 3600, seeds: 500)
        let decision = SeedEvaluator.evaluate(snapshot: snap, policy: .archive)
        XCTAssertFalse(decision.shouldStop)
    }

    func testTemporaryFlagsEligibilityForCleanup() {
        let snap = snapshot(uploaded: 1_200, downloaded: 1_000, seedSeconds: 0, seeds: 15)
        let decision = SeedEvaluator.evaluate(snapshot: snap, policy: .temporary)
        XCTAssertTrue(decision.shouldStop)
        XCTAssertTrue(decision.reasons.contains { $0.contains("Ready for cleanup") })
    }

    func testCustomGoalRespected() {
        let goal = SeedGoal(targetRatio: 3.0, minimumSeedSeconds: nil)
        let low = snapshot(uploaded: 1_500, downloaded: 1_000, seedSeconds: 0, seeds: 50)
        XCTAssertFalse(SeedEvaluator.evaluate(snapshot: low, policy: .custom(goal)).shouldStop)

        let high = snapshot(uploaded: 3_100, downloaded: 1_000, seedSeconds: 0, seeds: 50)
        XCTAssertTrue(SeedEvaluator.evaluate(snapshot: high, policy: .custom(goal)).shouldStop)
    }

    func testIncompleteTorrentsAreNeverStopped() {
        let snap = snapshot(progress: 0.4, uploaded: 0, downloaded: 400, seedSeconds: 0, seeds: 8, state: .downloading)
        XCTAssertFalse(SeedEvaluator.evaluate(snapshot: snap, policy: .balanced).shouldStop)
    }
}
