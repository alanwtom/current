import XCTest
@testable import CurrentCore

final class CleanupPlannerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeSnapshot(
        _ name: String,
        state: TorrentState = .seeding,
        progress: Double = 1,
        totalBytes: Int64 = 1_000_000_000,
        uploaded: Int64 = 2_000_000_000,
        seedSeconds: TimeInterval = 30 * 3600,
        seeds: Int = 40,
        pinned: Bool = false,
        completedDaysAgo: Double? = 60,
        lastActivityDaysAgo: Double? = 60
    ) -> TorrentSnapshot {
        TorrentSnapshot(
            id: TorrentID(name),
            name: name,
            state: state,
            progress: progress,
            totalBytes: totalBytes,
            downloadedBytes: totalBytes,
            uploadedBytes: uploaded,
            swarm: SwarmSummary(connectedSeeds: seeds, connectedPeers: 3, knownSeeds: seeds),
            addedAt: now.addingTimeInterval(-completedDaysAgo! * 86_400 - 3600),
            completedAt: completedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            lastActivityAt: lastActivityDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) },
            activeSeedSeconds: seedSeconds,
            saveDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(name, isDirectory: true),
            pinned: pinned
        )
    }

    private var balancedPolicies: [TorrentID: SeedPolicy] { [:] }

    func testEligibleOldLargeHealthyTorrentRanksFirst() {
        let ideal = makeSnapshot("ideal", totalBytes: 20_000_000_000, uploaded: 30_000_000_000)
        let freshSmall = makeSnapshot("fresh", totalBytes: 500_000_000, completedDaysAgo: 1, lastActivityDaysAgo: 1)

        let plan = CleanupPlanner.plan(snapshots: [freshSmall, ideal], policies: balancedPolicies, now: now)

        XCTAssertEqual(plan.candidates.count, 2)
        XCTAssertEqual(plan.candidates.first?.id, ideal.id)
        XCTAssertTrue(plan.candidates.first!.reasons.contains(where: { $0.contains("Swarm is healthy") }))
        XCTAssertEqual(plan.kept.isEmpty, true)
    }

    func testPinnedTorrentIsKept() {
        let pinned = makeSnapshot("pinned", pinned: true)
        let plan = CleanupPlanner.plan(snapshots: [pinned], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(plan.kept.first?.reasons, ["Pinned by you"])
    }

    func testRareTorrentNeverEligibleForAutomaticCleanup() {
        let rare = makeSnapshot("rare", seeds: 2)
        let plan = CleanupPlanner.plan(snapshots: [rare], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(plan.kept.first?.reasons.contains("Rare torrent — automatic cleanup leaves these alone"), true)
    }

    func testUnmetSeedGoalBlocksCleanup() {
        // Ratio far below the Balanced target.
        let lowRatio = makeSnapshot("low-ratio", uploaded: 100_000_000)
        let plan = CleanupPlanner.plan(snapshots: [lowRatio], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testArchivePolicyBlocksCleanup() {
        let archived = makeSnapshot("archive-me")
        let plan = CleanupPlanner.plan(
            snapshots: [archived],
            policies: [archived.id: .archive],
            now: now
        )
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testTemporaryGoalMetMakesEligible() {
        // Temporary has no time requirement; ratio met → eligible quickly.
        let temporary = makeSnapshot(
            "temp",
            uploaded: 1_200_000_000,
            seedSeconds: 60,
            completedDaysAgo: 10,
            lastActivityDaysAgo: 10
        )
        let plan = CleanupPlanner.plan(
            snapshots: [temporary],
            policies: [temporary.id: .temporary],
            now: now
        )
        XCTAssertEqual(plan.candidates.count, 1)
    }

    func testIncompleteDownloadsAreKept() {
        let partial = makeSnapshot("partial", state: .downloading, progress: 0.4)
        let paused = makeSnapshot("paused", state: .paused(.user), progress: 0.8)
        let plan = CleanupPlanner.plan(snapshots: [partial, paused], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(plan.kept.count, 2)
    }

    func testActiveTransfersAreKept() {
        let active = makeSnapshot("active")
        var withRates = active
        withRates.uploadRate = 500_000
        let plan = CleanupPlanner.plan(snapshots: [withRates], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
    }

    func testSharedDirectoryBlocksCleanup() {
        let directory = URL(fileURLWithPath: "/tmp/shared")
        var first = makeSnapshot("first")
        first.saveDirectory = directory
        var second = makeSnapshot("second")
        second.saveDirectory = directory

        let plan = CleanupPlanner.plan(snapshots: [first, second], policies: balancedPolicies, now: now)
        XCTAssertTrue(plan.candidates.isEmpty)
        XCTAssertEqual(Set(plan.kept.map(\.id)), Set([first.id, second.id]))
    }

    func testCandidatesToReachTargetStopsEarly() {
        let big = makeSnapshot("big", totalBytes: 10_000_000_000, uploaded: 15_000_000_000)
        let small1 = makeSnapshot("s1", totalBytes: 1_000_000_000, completedDaysAgo: 30, lastActivityDaysAgo: 30)
        let small2 = makeSnapshot("s2", totalBytes: 1_000_000_000, completedDaysAgo: 90, lastActivityDaysAgo: 90)

        let plan = CleanupPlanner.plan(snapshots: [small1, small2, big], policies: balancedPolicies, now: now)
        let needed = plan.candidatesToReach(freeBytesTarget: 11_000_000_000)
        XCTAssertGreaterThanOrEqual(needed.reduce(Int64(0)) { $0 + $1.reclaimableBytes }, 11_000_000_000)
    }

    func testEveryCandidateCarriesReasons() {
        let candidate = makeSnapshot("explained")
        let plan = CleanupPlanner.plan(snapshots: [candidate], policies: balancedPolicies, now: now)
        XCTAssertFalse(plan.candidates.first!.reasons.isEmpty)
    }
}
