import XCTest
@testable import CurrentCore

/// Regression cover for a torrent with **335 seeders on its tracker page**
/// sitting in the library labelled *Rare · 0 seeds*, under an amber callout
/// offering to help preserve it.
///
/// The cause was the measurement, not the thresholds: rarity was judged from
/// `connectedSeeds` — the seeds this Mac has an open connection to — and that
/// is zero for anything paused, and for anything added in the last few seconds.
/// The swarm's real size (`num_complete`, the figure a tracker reports and a
/// torrent site prints) was never read at all.
///
/// It mattered beyond the label. `SeedEvaluator` keeps seeding a rare torrent
/// past its goal and `CleanupPlanner` refuses to clean one, so the artefact was
/// steering what the app *did* — both are covered at the bottom of this file.
final class SwarmHealthTests: XCTestCase {

    // MARK: - The bug

    /// The exact reported case: paused, so nothing is connected, but the
    /// tracker says the swarm is large.
    func testAPausedTorrentInALargeSwarmIsNotRare() {
        let swarm = SwarmSummary(
            connectedSeeds: 0,
            connectedPeers: 0,
            knownSeeds: 0,
            swarmSeeds: 335,
            swarmPeers: 45
        )
        XCTAssertEqual(SwarmHealth(swarm: swarm), .healthy)
    }

    /// And with nothing reported at all, the answer is "don't know" — never
    /// "rare". Absence of evidence is not evidence of an empty swarm.
    func testNoInformationIsUnknownRatherThanRare() {
        let swarm = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
        XCTAssertEqual(SwarmHealth(swarm: swarm), .unknown)
        XCTAssertFalse(SwarmHealth(swarm: swarm).isKnown)
    }

    // MARK: - Evidence, in order of trust

    func testTheTrackersFigureWinsOverOurConnectionCount() {
        // Connected to one seed, but the tracker has counted hundreds.
        let swarm = SwarmSummary(
            connectedSeeds: 1,
            connectedPeers: 2,
            knownSeeds: 1,
            swarmSeeds: 335
        )
        XCTAssertEqual(SwarmHealth(swarm: swarm), .healthy)
    }

    /// The same precedence, pointing the other way — and this is the direction
    /// with consequences.
    ///
    /// Trusting the tracker over the peer list is easy to accept when it makes
    /// a torrent look better. It has to hold when it makes one look worse too,
    /// because `.rare` is not just a label: Helpful mode seeds a rare torrent
    /// past its goal indefinitely, and cleanup refuses to touch one. A stale
    /// peer list outvoting a tracker that says the swarm has emptied out would
    /// quietly keep uploading forever.
    func testTheTrackersFigureAlsoWinsWhenItIsWorseNews() {
        // Forty seeds in our peer list from an old announce; the tracker's
        // latest scrape says the swarm is down to one.
        let swarm = SwarmSummary(
            connectedSeeds: 12,
            connectedPeers: 30,
            knownSeeds: 40,
            swarmSeeds: 1
        )
        XCTAssertEqual(SwarmHealth(swarm: swarm), .rare)
    }

    /// Zero from a tracker is a measurement; nil is the absence of one. They
    /// must not collapse into each other — that collapse is the whole bug this
    /// type was rebuilt to fix.
    func testATrackerReportingZeroIsRareNotUnknown() {
        let measured = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 40, swarmSeeds: 0)
        XCTAssertEqual(SwarmHealth(swarm: measured), .rare)

        let unmeasured = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
        XCTAssertEqual(SwarmHealth(swarm: unmeasured), .unknown)
    }

    func testFallsBackToThePeerListWhenNoTrackerHasReported() {
        let swarm = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 40)
        XCTAssertEqual(SwarmHealth(swarm: swarm), .healthy)
    }

    /// Connections can confirm that seeds exist. They can never establish that
    /// they don't.
    func testConnectionsOnlyEverConfirm() {
        let connected = SwarmSummary(connectedSeeds: 5, connectedPeers: 5, knownSeeds: 0)
        XCTAssertEqual(SwarmHealth(swarm: connected), .moderate)

        let none = SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
        XCTAssertEqual(SwarmHealth(swarm: none), .unknown)
    }

    // MARK: - Genuinely rare swarms still register

    /// The fix must not simply silence the feature: a tracker that reports a
    /// nearly-dead swarm is exactly when this should speak up.
    func testATrackerReportingAlmostNoSeedsIsRare() {
        for seeds in 0...2 {
            let swarm = SwarmSummary(
                connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0, swarmSeeds: seeds
            )
            XCTAssertEqual(SwarmHealth(swarm: swarm), .rare, "\(seeds) seeds should read as rare")
        }
    }

    func testThresholds() {
        func health(_ seeds: Int) -> SwarmHealth {
            SwarmHealth(swarmSeeds: seeds)
        }
        XCTAssertEqual(health(2), .rare)
        XCTAssertEqual(health(3), .moderate)
        XCTAssertEqual(health(9), .moderate)
        XCTAssertEqual(health(10), .healthy)
    }

    /// -1 is the shim's "nobody has told us", and it must not be read as a
    /// count. It's turned into nil at the engine boundary; this pins the
    /// behaviour in case a raw value ever reaches here.
    func testNegativeSeedCountMeansUnknown() {
        XCTAssertEqual(SwarmHealth(swarmSeeds: -1), .unknown)
    }

    // MARK: - What the automation does with it

    private func completeSnapshot(swarm: SwarmSummary) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID("test"),
            name: "Test",
            state: .seeding,
            progress: 1,
            totalBytes: 1_000,
            downloadedBytes: 1_000,
            uploadedBytes: 5_000,
            swarm: swarm,
            addedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 30),
            completedAt: Date(timeIntervalSinceNow: -60 * 60 * 24 * 20),
            activeSeedSeconds: 60 * 60 * 30
        )
    }

    /// Seeding indefinitely is a real cost to impose, and "we have no
    /// information" is not a reason to impose it. Helpful mode used to keep
    /// every paused torrent alive on exactly that non-reason.
    func testHelpfulModeDoesNotSeedForeverOnAnUnmeasuredSwarm() {
        let unknown = completeSnapshot(
            swarm: SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
        )
        let decision = SeedEvaluator.evaluate(snapshot: unknown, policy: .helpful, now: Date())
        XCTAssertTrue(decision.shouldStop, "an unmeasured swarm shouldn't extend seeding")

        // A swarm the tracker says is nearly dead still does.
        let rare = completeSnapshot(
            swarm: SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0, swarmSeeds: 1)
        )
        let kept = SeedEvaluator.evaluate(snapshot: rare, policy: .helpful, now: Date())
        XCTAssertFalse(kept.shouldStop)
        XCTAssertTrue(kept.reasons.contains { $0.contains("Helpful mode") })
    }

    /// Cleanup goes the other way on purpose: it removes files from disk on its
    /// own, so the conservative answer to "is this rare?" when nobody has told
    /// us is *leave it alone*.
    func testCleanupWontTouchATorrentItCannotAssess() {
        let unknown = completeSnapshot(
            swarm: SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0)
        )
        let plan = CleanupPlanner.plan(
            snapshots: [unknown],
            policies: [unknown.id: .temporary],
            now: Date()
        )
        XCTAssertTrue(plan.candidates.isEmpty, "an unmeasured swarm shouldn't be cleaned")
        XCTAssertEqual(plan.kept.count, 1)

        // Measured and healthy: eligible, as before.
        let healthy = completeSnapshot(
            swarm: SwarmSummary(connectedSeeds: 0, connectedPeers: 0, knownSeeds: 0, swarmSeeds: 335)
        )
        let healthyPlan = CleanupPlanner.plan(
            snapshots: [healthy],
            policies: [healthy.id: .temporary],
            now: Date()
        )
        XCTAssertEqual(healthyPlan.candidates.count, 1)
        XCTAssertTrue(
            healthyPlan.candidates[0].reasons.contains { $0.contains("335 seeds") },
            "the reason should quote the swarm's size, not our connection count"
        )
    }
}
