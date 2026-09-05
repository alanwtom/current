import XCTest
import SwiftUI
@testable import CurrentApp

/// Renders the launch intro offscreen and looks at the pixels.
///
/// This exists because the bugs it covers were invisible to every other kind of
/// check. The intro compiled, ran, hurt nothing, and passed every test in the
/// suite — and the last thing you saw at launch was one bright dot sitting alone
/// on an empty window, because the drop assigned its own opacity over the one it
/// inherited instead of multiplying into it. Nothing but looking at a frame
/// would have caught that.
///
/// The drop has now been through four designs, so most of what's here is about
/// telling them apart. Worth knowing what the current one is before reading the
/// assertions: a rounded frontier crosses the drop from the top down, clipped to
/// the drop's outline, so the drop's top edge is finished from the first frame
/// and the only thing that moves is the boundary between inked and un-inked.
@MainActor
final class LaunchIntroTests: XCTestCase {

    private let canvasSize = CGSize(width: 320, height: 260)

    /// Measured off a rendered frame, not derived: the four waves occupy rows
    /// up to 0.573 of the canvas and the drop occupies 0.581 to 0.617. This band
    /// holds the drop and nothing else, which is what lets the assertions below
    /// count pixels directly — an earlier version of this file used a band that
    /// caught the narrowest wave's tail as well, and had to subtract a baseline
    /// to get numbers that meant anything.
    private var dropRegion: CGRect { CGRect(x: 0.44, y: 0.575, width: 0.12, height: 0.05) }
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

    /// How much of a region is lit, as a pixel count.
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

    /// Topmost and bottommost lit rows of the drop, in pixels. Nil if unlit.
    private func dropEdges(_ rep: NSBitmapImageRep) -> (top: Int, bottom: Int)? {
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        var top = Int.max, bottom = -1
        for y in stride(from: Int(dropRegion.minY * h), to: Int(dropRegion.maxY * h), by: 1) {
            for x in stride(from: Int(dropRegion.minX * w), to: Int(dropRegion.maxX * w), by: 1) {
                if let c = rep.colorAt(x: x, y: y), Double(c.brightnessComponent) > 0.5 {
                    top = min(top, y)
                    bottom = max(bottom, y)
                    break
                }
            }
        }
        return bottom < 0 ? nil : (top, bottom)
    }

    private func stageTime(_ fraction: Double) -> TimeInterval {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        return stages.dropStart + stages.dropDraw * fraction
    }

    // MARK: - The drop is drawn, not scaled

    /// The one that defines the whole design: the drop's **top edge is finished
    /// and in its final place from the first frame**, and only the frontier
    /// below it moves.
    ///
    /// That anchor is the entire difference between ink being laid down and a
    /// shape changing size, and every rejected version lacked it. A drop that
    /// grows from its centre moves both edges. A drop that falls moves both
    /// edges. A frontier sweeping across the other axis is symmetric top to
    /// bottom, so nothing is pinned, and at the size this is actually seen —
    /// about 10pt — that reads as the drop stretching sideways.
    ///
    /// If this fails, the drop is no longer being drawn, whatever else it does.
    func testTheDropsTopEdgeIsFinishedFromTheFirstFrame() throws {
        let finished = try XCTUnwrap(dropEdges(try render(elapsed: stageTime(1))))

        for fraction in [0.1, 0.25, 0.5, 0.75] {
            let edges = try XCTUnwrap(
                dropEdges(try render(elapsed: stageTime(fraction))),
                "the drop should be visible \(Int(fraction * 100))% through its stage"
            )
            XCTAssertEqual(
                edges.top, finished.top, accuracy: 1,
                """
                \(Int(fraction * 100))% through its stage the drop's top edge was at \
                \(edges.top) rather than its final \(finished.top) — the drop is \
                moving or resizing, not being inked in from a fixed edge
                """
            )
        }
    }

    /// The frontier keeps moving into the last part of the stage.
    ///
    /// Not a nicety. Under the `easeOut` the rest of the intro uses — a cube —
    /// the frontier had crossed the drop by 56% of its stage and every frame
    /// after that was pixel-for-pixel identical: a third of the finale doing
    /// nothing, with no other element still animating to cover for it. The
    /// squared ease this uses now spreads the same movement across roughly 85%.
    func testTheDropIsStillFillingLateInItsStage() throws {
        let done = inkPixels(try render(elapsed: stageTime(1)), in: dropRegion)
        let half = inkPixels(try render(elapsed: stageTime(0.5)), in: dropRegion)
        let threeQuarters = inkPixels(try render(elapsed: stageTime(0.75)), in: dropRegion)

        // Measured, both curves, same frames: squared runs 79% / 97% / 100% at
        // the half, three-quarter and full marks; cubed runs 92% / 100% / 100%.
        // 85% sits between them with room on each side, and the second
        // assertion is the blunt one — under the cube the drop is *finished* at
        // three quarters, so any margin at all catches it.
        XCTAssertLessThan(
            Double(half), Double(done) * 0.85,
            """
            halfway through its stage the drop was already \
            \(Int(Double(half) / Double(done) * 100))% filled — the ease is \
            front-loaded, and the finale ends with dead frames
            """
        )
        XCTAssertLessThan(
            threeQuarters, done,
            "the drop had finished filling three quarters of the way through its own stage"
        )
    }

    /// The drop builds up over its stage instead of appearing complete.
    ///
    /// Three earlier versions are worth remembering, because each read fine in
    /// the code and wrong on screen:
    ///
    /// It first **flew in** — born up in the stack and falling to rest — which
    /// at speed teleported: 63% of the journey inside the first quarter of the
    /// time, so you saw it about twice at 60fps. Eased properly it was still one
    /// object moving through an otherwise still composition.
    ///
    /// Then it **grew** from nothing, which is not drawing, and looks it.
    ///
    /// Then it was **literally traced**, as a trimmed circular stroke like the
    /// four lines — which cannot work, for a reason easy to rediscover and hard
    /// to see coming: a dot's finished shape *is* a single round line cap, so
    /// the stroke paints most of it on the first frame, and flattening the cap
    /// to stop that turns the sweep into a pie chart with hard radial edges.
    func testTheDropBuildsUpRatherThanAppearing() throws {
        let early = inkPixels(try render(elapsed: stageTime(0.25)), in: dropRegion)
        let done = inkPixels(try render(elapsed: stageTime(1)), in: dropRegion)

        XCTAssertGreaterThan(done, 200, "the finished drop should be a solid dot, not a speck")
        XCTAssertGreaterThan(early, 0, "the drop should have started a quarter of the way through")
        XCTAssertLessThan(
            Double(early), Double(done) * 0.7,
            """
            a quarter of the way in the drop was already \
            \(Int(Double(early) / Double(done) * 100))% of its final area — \
            it is appearing, not being drawn
            """
        )
    }

    /// Nothing travels. The drop ends up where the icon says it goes and was
    /// never anywhere else — a falling drop would light the gap between the
    /// narrowest wave and the drop's resting place partway through. Clipping the
    /// frontier to the drop's outline can never trip this, which is the point:
    /// the technique makes the old bug unreachable rather than unlikely.
    func testTheDropNeverAppearsAboveItsRestingPlace() throws {
        // Measured: the waves stop at 0.573 and the drop starts at 0.581.
        let gap = CGRect(x: 0.44, y: 0.574, width: 0.12, height: 0.006)
        let fadeStart = LaunchIntro.Stages(reduceMotion: false).fadeStart
        let finished = inkPixels(try render(elapsed: fadeStart), in: gap)

        for fraction in [0.2, 0.4, 0.6, 0.8] {
            let mid = inkPixels(try render(elapsed: stageTime(fraction)), in: gap)
            XCTAssertLessThanOrEqual(
                mid, finished + 12,
                "at \(Int(fraction * 100))% the drop was lighting the gap above its resting place"
            )
        }
    }

    // MARK: - The drop belongs to the icon

    /// The regression that started all of this. The drop must dissolve on the
    /// same schedule as everything else, because it is part of the same icon.
    func testTheDropFadesOutWithTheRestOfTheIcon() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        // Three quarters of the way through the dissolve: well faded, not gone.
        let rep = try render(elapsed: stages.fadeStart + stages.fade * 0.75)

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
            "the drop should be complete and at full strength when the fade begins"
        )
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
