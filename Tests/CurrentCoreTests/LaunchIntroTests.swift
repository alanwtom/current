import XCTest
import SwiftUI
@testable import CurrentApp

/// Renders the launch intro offscreen and looks at the pixels.
///
/// This exists because the bug it covers was invisible to every other kind of
/// check. The intro compiled, ran, hurt nothing, and passed every test in the
/// suite — and the last thing you saw at launch was one bright dot sitting
/// alone on an empty window, because the drop assigned its own opacity over the
/// one it inherited instead of multiplying into it. Nothing but looking at a
/// frame would have caught that.
@MainActor
final class LaunchIntroTests: XCTestCase {

    private let canvasSize = CGSize(width: 320, height: 260)

    /// The drop sits low and centred; the waves are the band above it.
    private var dropRegion: CGRect { CGRect(x: 0.44, y: 0.56, width: 0.12, height: 0.10) }
    private var waveRegion: CGRect { CGRect(x: 0.35, y: 0.36, width: 0.30, height: 0.12) }

    private func render(elapsed: TimeInterval, reduceMotion: Bool = false) throws -> NSBitmapImageRep {
        let stages = LaunchIntro.Stages(reduceMotion: reduceMotion)
        let frame = LaunchIntro.Frame(
            stages: stages,
            veil: Color(red: 0.071, green: 0.071, blue: 0.078),
            iconSize: 128
        )
        let view = Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            var c = ctx
            frame.draw(in: &c, size: size, elapsed: elapsed)
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .background(Color(red: 0.071, green: 0.071, blue: 0.078))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.nsImage)
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return NSBitmapImageRep(cgImage: cg)
    }

    /// Brightest pixel in a region, as a fraction of the image's dimensions.
    private func brightness(_ rep: NSBitmapImageRep, in unit: CGRect) -> Double {
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        var maxB = 0.0
        for y in stride(from: Int(unit.minY * h), to: Int(unit.maxY * h), by: 2) {
            for x in stride(from: Int(unit.minX * w), to: Int(unit.maxX * w), by: 2) {
                if let c = rep.colorAt(x: x, y: y) {
                    maxB = max(maxB, Double(c.brightnessComponent))
                }
            }
        }
        return maxB
    }

    /// The regression. The drop must dissolve on the same schedule as
    /// everything else, because it is part of the same icon.
    func testTheDropFadesOutWithTheRestOfTheIcon() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        // Three quarters of the way through the dissolve: well faded, not gone.
        let late = stages.fadeStart + stages.fade * 0.75
        let rep = try render(elapsed: late)

        let drop = brightness(rep, in: dropRegion)
        let waves = brightness(rep, in: waveRegion)

        XCTAssertLessThan(
            abs(drop - waves), 0.10,
            "the drop (\(drop)) and the waves (\(waves)) should be fading together"
        )
        XCTAssertLessThan(drop, 0.45, "the drop should be most of the way gone by now")
    }

    /// Guards the assertion above from passing because nothing is drawn at all.
    func testTheDropIsFullyDrawnBeforeTheDissolveStarts() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        let rep = try render(elapsed: stages.fadeStart)
        XCTAssertGreaterThan(
            brightness(rep, in: dropRegion), 0.6,
            "the drop should have arrived and be at full strength when the fade begins"
        )
    }

    /// How much of a region is lit, as a pixel count — enough to tell a
    /// half-built mark from a finished one.
    private func inkPixels(_ rep: NSBitmapImageRep, in unit: CGRect) -> Int {
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        var lit = 0
        for y in stride(from: Int(unit.minY * h), to: Int(unit.maxY * h), by: 1) {
            for x in stride(from: Int(unit.minX * w), to: Int(unit.maxX * w), by: 1) {
                if let c = rep.colorAt(x: x, y: y), Double(c.brightnessComponent) > 0.5 {
                    lit += 1
                }
            }
        }
        return lit
    }

    /// The drop builds up over its own stage instead of appearing complete.
    ///
    /// Two earlier versions are worth remembering, because both read fine in
    /// the code and wrong on screen. It first *flew* in — born up in the stack
    /// and falling to rest — which at speed teleported: 63% of the journey
    /// inside the first quarter of the time, so you saw it about twice at
    /// 60fps. Eased properly it was still one object moving through an
    /// otherwise still composition, pulling the eye exactly when the mark
    /// should have been settling. Then it was literally traced, as a trimmed
    /// circular stroke like the four lines — which cannot work, for a reason
    /// that is easy to rediscover and hard to see coming: a dot's finished
    /// shape *is* a single round cap, so the stroke paints most of it on the
    /// first frame, and flattening the cap to stop that turns the sweep into a
    /// pie chart with hard radial edges.
    ///
    /// So it grows. What is guarded is the property all three versions had to
    /// satisfy and only this one does cleanly: partway through its own stage,
    /// the dot is visibly unfinished.
    func testTheDropBuildsUpRatherThanAppearing() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        let at = { (f: Double) in stages.dropStart + stages.dropDraw * f }

        // The wave above bleeds into the region, so measure the dot against the
        // frame just before it starts rather than against zero. Without this,
        // the numbers being compared are more tail than dot: measured, the tail
        // is 193 lit pixels and the finished dot another 334.
        let baseline = inkPixels(try render(elapsed: at(0)), in: dropRegion)
        let dot = { (f: Double) in
            try self.inkPixels(self.render(elapsed: at(f)), in: self.dropRegion) - baseline
        }

        let early = try dot(0.25)
        let done = try dot(1.0)

        // Fails both ways that matter: a dot that never draws, and one that was
        // already whole before its stage began — then it adds nothing during it.
        XCTAssertGreaterThan(
            done, 200,
            "the drop added almost nothing over its own stage — it either never drew, or it was already complete when the stage started"
        )
        XCTAssertGreaterThan(early, 0, "the drop should have started a quarter of the way through")
        XCTAssertLessThan(
            Double(early), Double(done) * 0.6,
            "a quarter of the way in the drop was already \(Int(Double(early) / Double(done) * 100))% of its final size — it is appearing, not building up"
        )
        XCTAssertGreaterThan(try dot(0.6), early, "the drop should still be growing at 60%")
    }

    /// Nothing travels. The dot ends up where the icon says it goes and was
    /// never anywhere else — a falling dot would light pixels above its resting
    /// place partway through. This is what stops the flown-in version coming
    /// back; growing from the centre can never trip it.
    func testTheDropNeverAppearsAboveItsRestingPlace() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        // The gap between the last wave and the drop: empty in a finished icon.
        let gap = CGRect(x: 0.44, y: 0.515, width: 0.12, height: 0.035)
        let finished = inkPixels(try render(elapsed: stages.fadeStart), in: gap)

        for fraction in [0.2, 0.4, 0.6, 0.8] {
            let mid = inkPixels(
                try render(elapsed: stages.dropStart + stages.dropDraw * fraction),
                in: gap
            )
            XCTAssertLessThanOrEqual(
                mid, finished + 12,
                "at \(Int(fraction * 100))% the drop was lighting the gap above its resting place"
            )
        }
    }

    /// Reduce Motion gets the finished icon, immediately, with nothing
    /// travelling — and the drop is part of "finished".
    func testReduceMotionShowsACompleteIconWithNoTravel() throws {
        let stages = LaunchIntro.Stages(reduceMotion: true)
        let rep = try render(elapsed: stages.plateIn, reduceMotion: true)
        XCTAssertGreaterThan(brightness(rep, in: dropRegion), 0.6, "the drop should be present at rest")
        XCTAssertGreaterThan(brightness(rep, in: waveRegion), 0.6, "the waves should be fully drawn")
    }
}
