import XCTest
@testable import CurrentCore

final class BandwidthPolicyTests: XCTestCase {

    private let normal = RateLimits(download: 0, upload: 0)          // unlimited
    private let slow = RateLimits(download: 500_000, upload: 100_000)

    private func policy(
        forced: Bool = false,
        onBattery: Bool = false
    ) -> BandwidthPolicy {
        BandwidthPolicy(
            normal: normal,
            reduced: slow,
            isReducedForced: forced,
            reduceOnBattery: onBattery
        )
    }

    func testNormalLimitsApplyByDefault() {
        XCTAssertEqual(policy().effectiveLimits(onBattery: false), normal)
        XCTAssertEqual(policy().effectiveLimits(onBattery: true), normal)
    }

    func testForcedReductionIgnoresPowerSource() {
        let p = policy(forced: true)
        XCTAssertEqual(p.effectiveLimits(onBattery: false), slow)
        XCTAssertEqual(p.effectiveLimits(onBattery: true), slow)
    }

    /// The regression that matters: this setting shipped wired to nothing, so
    /// turning it on had no effect whatsoever.
    func testBatteryReductionOnlyAppliesOnBattery() {
        let p = policy(onBattery: true)
        XCTAssertEqual(p.effectiveLimits(onBattery: false), normal)
        XCTAssertEqual(p.effectiveLimits(onBattery: true), slow)
    }

    /// Every way the speed can be limited explains itself, and each in its own
    /// words — the same sentence for "you switched it on" and "you're on
    /// battery" would answer "why is this slow?" with nothing.
    func testEveryReductionPathIsExplainedDifferently() {
        let reasons = [
            policy(forced: true).explanation(onBattery: false),
            policy(onBattery: true).explanation(onBattery: true),
            policy().explanation(onBattery: false),
        ]
        XCTAssertFalse(reasons.contains(where: \.isEmpty))
        XCTAssertEqual(Set(reasons).count, reasons.count)
    }

    func testZeroMeansUnlimitedAndNegativesAreClamped() {
        XCTAssertTrue(RateLimits.unlimited.isUnlimited)
        XCTAssertEqual(RateLimits(download: -5, upload: -1), .unlimited)
        XCTAssertFalse(RateLimits(download: 1, upload: 0).isUnlimited)
    }

    func testConfigurationClampsNonsenseValues() {
        let config = EngineConfiguration(
            maxConnections: 0,
            maxUploadSlots: -3,
            maxActiveDownloads: 0
        )
        XCTAssertEqual(config.maxConnections, 1)
        XCTAssertEqual(config.maxUploadSlots, 1)
        XCTAssertEqual(config.maxActiveDownloads, 1)
    }
}
