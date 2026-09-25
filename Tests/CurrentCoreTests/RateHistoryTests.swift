import XCTest
@testable import CurrentCore

final class RateHistoryTests: XCTestCase {

    private func history(capacity: Int = 8, _ pairs: [(Double, Double)]) -> RateHistory {
        var history = RateHistory(capacity: capacity)
        for (down, up) in pairs { history.record(down: down, up: up) }
        return history
    }

    // MARK: - The window

    func testStartsEmptyAndSilent() {
        let history = RateHistory()
        XCTAssertEqual(history.count, 0)
        XCTAssertTrue(history.isSilent)
        XCTAssertEqual(history.latest, .idle)
        XCTAssertEqual(history.span, 0)
    }

    func testOldestSamplesFallOffTheEnd() {
        let history = self.history(capacity: 3, [(1, 0), (2, 0), (3, 0), (4, 0)])
        XCTAssertEqual(history.count, 3)
        XCTAssertEqual(history.samples.map(\.down), [2, 3, 4])
        XCTAssertEqual(history.latest.down, 4)
    }

    /// A capacity of one would make the graph a single point with no line
    /// between anything, so the floor is two.
    func testCapacityCannotDropBelowTwo() {
        var history = RateHistory(capacity: 0)
        history.record(down: 1, up: 1)
        history.record(down: 2, up: 2)
        XCTAssertEqual(history.count, 2)
    }

    /// libtorrent has been seen to report a small negative rate on the tick a
    /// torrent is torn down. A negative sample would draw the curve through the
    /// wrong half of the graph.
    func testNegativeRatesAreClampedToZero() {
        let history = self.history([(-5_000, -1)])
        XCTAssertEqual(history.latest.down, 0)
        XCTAssertEqual(history.latest.up, 0)
    }

    // MARK: - Silence

    func testASubByteTrickleStillCountsAsSilent() {
        // Rates decay to a fraction of a byte for several ticks after a
        // transfer stops, and a graph that calls that "active" never rests.
        XCTAssertTrue(history([(0.4, 0.9), (0, 0)]).isSilent)
    }

    func testAnythingMovingBreaksSilence() {
        XCTAssertFalse(history([(0, 0), (2_048, 0)]).isSilent)
    }

    // MARK: - The shared scale

    func testPeakTakesTheFastestSampleInEitherDirection() {
        XCTAssertEqual(history([(100, 900), (400, 200)]).peak, 900)
    }

    func testPerDirectionPeaksAreKeptApart() {
        let history = self.history([(100, 900), (400, 200)])
        XCTAssertEqual(history.downPeak, 400)
        XCTAssertEqual(history.upPeak, 900)
    }

    func testScaleIsSharedSoUpAndDownStayComparable() {
        // Ten times the download rate has to draw ten times the height, or the
        // two halves say nothing about each other.
        let history = self.history([(10 * 1024 * 1024, 1024 * 1024)])
        let down = history.fraction(history.latest.down)
        let up = history.fraction(history.latest.up)
        XCTAssertEqual(down / up, 10, accuracy: 0.001)
    }

    func testThePeakKeepsHeadroomOffTheFrame() {
        let history = self.history([(4 * 1024 * 1024, 0)])
        let fraction = history.fraction(history.peak)
        XCTAssertEqual(fraction, RateHistory.headroom, accuracy: 0.001)
        XCTAssertLessThan(fraction, 1)
    }

    // MARK: - Where the zero line sits

    func testAnIdleWindowCentresTheBaseline() {
        XCTAssertEqual(RateHistory().baselinePosition, 0.5)
        XCTAssertEqual(history([(0, 0), (0, 0)]).baselinePosition, 0.5)
    }

    func testEvenGiveAndTakeCentresTheBaseline() {
        let history = self.history([(1024 * 1024, 1024 * 1024)])
        XCTAssertEqual(history.baselinePosition, 0.5, accuracy: 0.0001)
    }

    /// A download four times the upload gets four fifths of the frame, so the
    /// zero line sits a fifth of the way down. The old centred baseline left
    /// the other four fifths of the upper half as dead black.
    func testTheBaselineRidesUpWhenDownloadDominates() {
        let history = self.history([(4 * 1024 * 1024, 1024 * 1024)])
        XCTAssertEqual(history.baselinePosition, 0.2, accuracy: 0.0001)
    }

    /// A pure seed is downloading nothing, so the line goes to the bottom and
    /// the whole frame is upload — the mirror image of a fresh download, and
    /// the reason this is worth having: the same card describes both without
    /// wasting half of itself on either.
    func testTheBaselineDropsAllTheWayWhenOnlySeeding() {
        let history = self.history([(0, 4 * 1024 * 1024)])
        XCTAssertEqual(history.baselinePosition, 1, accuracy: 0.0001)
    }

    func testASeedThatIsAlsoTrickingInStillShowsTheDownload() {
        let history = self.history([(64 * 1024, 100 * 1024 * 1024)])
        XCTAssertEqual(history.baselinePosition, 1 - RateHistory.minimumShare, accuracy: 0.0001)
    }

    /// **The property that makes an off-centre baseline honest.** Each half is
    /// as tall as its own peak, so a point of height is worth the same number
    /// of bytes above the line as below it — which is the comparison a single
    /// shared scale exists to protect.
    func testAPointOfHeightIsWorthTheSameInBothHalves() {
        let history = self.history([(6 * 1024 * 1024, 2 * 1024 * 1024)])
        let height = 100.0
        let downRoom = height * (1 - history.baselinePosition)
        let upRoom = height * history.baselinePosition

        let downBar = history.fraction(history.downPeak) * height
        let upBar = history.fraction(history.upPeak) * height
        // Each direction's tallest bar fills the same share of its own room.
        XCTAssertEqual(downBar / downRoom, upBar / upRoom, accuracy: 0.0001)
        XCTAssertEqual(downBar / downRoom, RateHistory.headroom, accuracy: 0.0001)
        // And the bar heights themselves still hold the 3:1 rate ratio.
        XCTAssertEqual(downBar / upBar, 3, accuracy: 0.0001)
    }

    /// Past about 12:1 the quiet direction would be given less height than its
    /// shortest bar needs, so the one tick proving a torrent is still
    /// uploading would be clipped away entirely.
    func testAVeryQuietDirectionStillGetsRoomToShow() {
        let history = self.history([(100 * 1024 * 1024, 64 * 1024)])
        XCTAssertEqual(history.baselinePosition, RateHistory.minimumShare, accuracy: 0.0001)
    }

    func testADirectionThatIsNotMovingIsGivenNoRoom() {
        // Nothing uploading at all: the line goes to the top and the whole
        // frame is the download. No floor, because there is nothing to show.
        let history = self.history([(8 * 1024 * 1024, 0)])
        XCTAssertEqual(history.baselinePosition, 0, accuracy: 0.0001)
    }

    func testATrickleStaysNearTheBaseline() {
        // 200 B/s used to fill the frame, because the scale was the peak and
        // the peak was 200 B/s.
        let history = self.history([(200, 0)])
        XCTAssertLessThan(history.fraction(200), 0.05)
    }

    func testAnEmptyWindowHasAScaleRatherThanDividingByZero() {
        let history = RateHistory()
        XCTAssertEqual(history.scale, RateHistory.scaleFloor)
        XCTAssertEqual(history.fraction(0), 0)
    }

    func testFractionIsClampedToTheFrame() {
        let history = self.history([(1024, 0)])
        XCTAssertEqual(history.fraction(.infinity), 1)
        XCTAssertEqual(history.fraction(-1), 0)
    }

    // MARK: - Scrubbing

    func testScrubbingTheRightHandEndReadsTheNewestSample() {
        let history = self.history([(1, 0), (2, 0), (3, 0), (4, 0)])
        let reading = history.reading(atX: 399, width: 400)
        XCTAssertEqual(reading?.sample.down, 4)
        XCTAssertEqual(reading?.secondsAgo, 0)
    }

    func testScrubbingTheLeftHandEndReadsTheOldestSample() {
        let history = self.history([(1, 0), (2, 0), (3, 0), (4, 0)])
        let reading = history.reading(atX: 0, width: 400)
        XCTAssertEqual(reading?.sample.down, 1)
        XCTAssertEqual(reading?.secondsAgo, 3)
    }

    /// **Each sample owns a slot, because each one is drawn as a bar.** Four
    /// samples across 400pt are four 100pt slots, and anywhere inside a slot
    /// reads that slot. Spacing them on `count - 1` gaps — right for a line
    /// chart, where a sample is an instant rather than a second — makes the
    /// right-hand half of the meter report the bar next door.
    func testEachSampleOwnsItsOwnSlot() {
        let history = self.history([(1, 0), (2, 0), (3, 0), (4, 0)])
        XCTAssertEqual(history.index(atX: 0, width: 400), 0)
        XCTAssertEqual(history.index(atX: 99, width: 400), 0)
        XCTAssertEqual(history.index(atX: 100, width: 400), 1)
        XCTAssertEqual(history.index(atX: 250, width: 400), 2)
        XCTAssertEqual(history.index(atX: 399, width: 400), 3)
    }

    /// One sample is one bar filling the frame, and it has to be readable —
    /// this is the state a torrent is in for its first second.
    func testASingleSampleFillsTheWholeWindow() {
        let history = self.history([(2_048, 0)])
        XCTAssertEqual(history.index(atX: 0, width: 200), 0)
        XCTAssertEqual(history.index(atX: 199, width: 200), 0)
    }

    /// The cursor can leave the view between two hover events, and a hover in a
    /// view whose width hasn't been measured yet reports against zero.
    func testScrubbingOutsideTheFrameStaysInsideTheWindow() {
        let history = self.history([(1, 0), (2, 0), (3, 0)])
        XCTAssertEqual(history.index(atX: -40, width: 200), 0)
        XCTAssertEqual(history.index(atX: 900, width: 200), 2)
        XCTAssertNil(history.index(atX: 40, width: 0))
        XCTAssertNil(RateHistory().index(atX: 40, width: 200))
    }

    /// The scale is the window's own peak, so it only moves when a peak enters
    /// the window or rolls off the far end — which is what stops the graph
    /// rescaling under the cursor every second.
    func testScaleOnlyFallsWhenThePeakLeavesTheWindow() {
        var history = RateHistory(capacity: 3)
        history.record(down: 8 * 1024 * 1024, up: 0)
        let tall = history.scale
        history.record(down: 1024, up: 0)
        XCTAssertEqual(history.scale, tall)
        history.record(down: 1024, up: 0)
        XCTAssertEqual(history.scale, tall)
        history.record(down: 1024, up: 0)
        XCTAssertLessThan(history.scale, tall)
    }
}
