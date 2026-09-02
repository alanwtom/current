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

    func testEveryReductionPathIsExplainable() {
        XCTAssertTrue(
            policy(forced: true).explanation(onBattery: false)
                .localizedCaseInsensitiveContains("switched on")
        )
        XCTAssertTrue(
            policy(onBattery: true).explanation(onBattery: true)
                .localizedCaseInsensitiveContains("battery")
        )
        XCTAssertTrue(
            policy().explanation(onBattery: false)
                .localizedCaseInsensitiveContains("no speed limit")
        )
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
