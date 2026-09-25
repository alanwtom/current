import Foundation

/// One tick's worth of throughput for one torrent.
public struct RateSample: Equatable, Sendable {
    /// Bytes per second coming in.
    public var down: Double
    /// Bytes per second going out.
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }

    public static let idle = RateSample(down: 0, up: 0)

    /// True when neither direction is meaningfully moving. The 1 B/s floor is
    /// the same one the rest of the app uses to decide whether to show a rate at
    /// all — libtorrent reports a decaying fraction of a byte for a while after
    /// a transfer actually stops.
    public var isIdle: Bool { down <= 1 && up <= 1 }
}

/// A torrent's recent throughput, as a fixed-length window.
///
/// Lives in Core because it is arithmetic, not drawing: the window, the shared
/// scale and the rounding all have exactly one correct answer, and the graph in
/// the inspector should not be the place those answers are worked out.
///
/// **Fixed capacity, oldest evicted first.** A ring of values rather than a
/// growing array, because this accumulates for every torrent in the library for
/// as long as the app runs. Ninety samples at the engines' one-second tick is
/// a minute and a half — long enough to see a download settle after it starts,
/// short enough that it costs nothing (90 pairs of doubles per torrent) and
/// short enough that the window's own peak still describes *now* rather than
/// something that happened ten minutes ago.
public struct RateHistory: Equatable, Sendable {

    /// How far apart two samples are, nominally.
    ///
    /// Both engines tick at one second — `LTShim`'s stats loop
    /// (`next_stats_tick = now + milliseconds(1000)`) and `SimulationEngine`'s
    /// default `tickInterval` — so the window's span is its sample count, and
    /// the graph can label its own x-axis without storing a date per sample.
    ///
    /// It is nominal on purpose. A tick that arrives late shifts the label by a
    /// fraction of a second, which is not worth 90 `Date`s per torrent and an
    /// x-axis that has to be spaced by time rather than by index.
    public static let sampleInterval: TimeInterval = 1

    /// A minute and a half.
    public static let defaultCapacity = 90

    public private(set) var samples: [RateSample]
    public let capacity: Int

    public init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(2, capacity)
        self.samples = []
        self.samples.reserveCapacity(self.capacity)
    }

    /// Adds one tick, dropping the oldest if the window is full.
    public mutating func record(down: Double, up: Double) {
        samples.append(RateSample(down: max(0, down), up: max(0, up)))
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    public var count: Int { samples.count }
    public var latest: RateSample { samples.last ?? .idle }

    /// How much time the window covers, so far.
    public var span: TimeInterval { TimeInterval(samples.count) * Self.sampleInterval }

    /// Nothing has moved in either direction for the whole window.
    ///
    /// What the graph draws instead of a flat line at zero, which on its own is
    /// indistinguishable from a graph that hasn't been wired up.
    public var isSilent: Bool { samples.allSatisfy(\.isIdle) }

    /// The fastest single sample in the window, per direction.
    public var downPeak: Double { samples.reduce(0) { max($0, $1.down) } }
    public var upPeak: Double { samples.reduce(0) { max($0, $1.up) } }

    /// The fastest single sample in the window, in **either** direction. What
    /// the meter labels itself with.
    public var peak: Double { max(downPeak, upPeak) }

    /// Bytes per second at the meter's full height.
    ///
    /// **One number for both directions, and that is the whole point of the
    /// meter.** Scaling up and down independently would fill both halves for
    /// any torrent doing anything at all, so a download running forty times
    /// faster than its upload would look evenly matched. Sharing the scale is
    /// what makes the two halves comparable, which is the only question a
    /// mirrored chart exists to answer.
    ///
    /// It is the *sum* of the two peaks rather than the larger of them, and
    /// that is what pairs it with `baselinePosition`: between them, the
    /// tallest bar in each direction reaches the same fraction of that
    /// direction's own half, and a point of height is worth the same number of
    /// bytes above the line as below it.
    ///
    /// Two adjustments, both load-bearing:
    ///
    /// - **Headroom.** The two peaks together reach 89% of the height rather
    ///   than all of it. A bar that touches the frame reads as clipped — as
    ///   though the real value were higher and the meter had run out of room.
    /// - **A floor.** With none, a window whose fastest moment was 200 B/s
    ///   drew a full-height mountain range out of a torrent that is barely
    ///   moving, and a window of pure zeros divided by zero.
    ///
    /// Autoscaling is honest here only because the scale is *drawn*: the card
    /// labels `peak`, so a shape that fills the frame can always be read
    /// against a real number.
    public var scale: Double {
        max(Self.scaleFloor, (downPeak + upPeak) / Self.headroom)
    }

    /// Where the zero line sits, as a fraction of the height from the top.
    ///
    /// **The baseline is not in the middle, and refusing to centre it is what
    /// makes the meter worth looking at.** Halving the frame and sharing the
    /// scale is the obvious arrangement and it wastes most of the card: an
    /// upload running at a tenth of the download — which is nearly every
    /// torrent — leaves nine tenths of the upper half as dead black, and the
    /// whole chart collapses into the bottom corner. Splitting the frame in
    /// proportion to the two peaks instead gives each direction exactly the
    /// room it needs, so neither half is ever empty.
    ///
    /// It costs nothing in honesty, which is the surprising part. Because each
    /// half's height is proportional to its own peak, a point of height is
    /// worth the same number of bytes in both — the comparison a shared scale
    /// exists for survives intact. And the line's *position* becomes a reading
    /// in itself: high in the frame means taking far more than giving, low
    /// means the reverse, centred means even.
    public var baselinePosition: Double {
        let total = downPeak + upPeak
        guard total > 0 else { return 0.5 }
        var up = upPeak / total
        // A direction that is moving at all has to have room to say so. Below
        // this there isn't height for the gap and the shortest bar, so the one
        // tick proving a torrent is still uploading would be clipped out of
        // existence. It is the only place the proportions are fudged, it is
        // bounded, and it only happens past about a 12:1 ratio.
        if upPeak > 0 { up = max(up, Self.minimumShare) }
        if downPeak > 0 { up = min(up, 1 - Self.minimumShare) }
        return up
    }

    /// The fraction of the meter's **full height** a value occupies, clamped.
    public func fraction(_ value: Double) -> Double {
        guard scale > 0 else { return 0 }
        return min(1, max(0, value / scale))
    }

    /// Which sample sits under a point `x` across a meter `width` wide.
    ///
    /// Here rather than in the view because it is arithmetic with exactly one
    /// right answer, and because the off-by-one is easy. **A sample owns a
    /// slot, not a point:** each one is a second of time drawn as a bar, so
    /// the window is `count` slots wide and the reading is whichever slot the
    /// cursor is inside. Spacing them on `count - 1` gaps instead — which is
    /// right for a line chart, where a sample is an instant — makes the
    /// right-hand half of the meter report the sample next door.
    public func index(atX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, !samples.isEmpty else { return nil }
        let slot = width / CGFloat(samples.count)
        let hit = Int((x / slot).rounded(.down))
        return min(samples.count - 1, max(0, hit))
    }

    /// The sample under that point, and how many seconds ago it was.
    public func reading(atX x: CGFloat, width: CGFloat) -> (sample: RateSample, secondsAgo: Int)? {
        guard let index = index(atX: x, width: width) else { return nil }
        let back = (samples.count - 1 - index) * Int(Self.sampleInterval)
        return (samples[index], back)
    }

    /// 8 KB/s. Below this a torrent is not transferring so much as ticking
    /// over, and the meter should say so by staying near the baseline.
    static let scaleFloor: Double = 8 * 1024
    /// The two peaks together reach 89% of the height.
    static let headroom: Double = 0.89
    /// The least of the frame a moving direction can be given — enough for the
    /// baseline gap and the shortest bar. See `baselinePosition`.
    static let minimumShare: Double = 0.08
}
