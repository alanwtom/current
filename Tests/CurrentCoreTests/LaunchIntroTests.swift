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

    /// Finds the bottom edge of the drop: it is the lowest thing drawn, so
    /// scanning up from the base of the image finds it before anything else.
    /// Returns a fraction of the image height, or nil if nothing is lit.
    private func dropBottomEdge(_ rep: NSBitmapImageRep) -> Double? {
        let w = rep.pixelsWide, h = rep.pixelsHigh
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in stride(from: Int(Double(w) * 0.44), to: Int(Double(w) * 0.56), by: 1) {
                if let c = rep.colorAt(x: x, y: y), Double(c.brightnessComponent) > 0.5 {
                    return Double(y) / Double(h)
                }
            }
        }
        return nil
    }

    /// The drop has to accelerate, not front-load its journey.
    ///
    /// The old version used `easeOut` — fastest at the instant it starts, then
    /// crawling — which is how something decelerating to a halt moves, not
    /// something falling. Combined with a 401-unit journey inside one
    /// `Motion.quick`, it put 63% of the distance in the first quarter of the
    /// time, so at 60fps the drop appeared roughly twice and read as a
    /// teleport. Measuring the position rather than the brightness is the point
    /// of this test: an earlier version watched one spot and happily passed
    /// with the bad easing restored.
    func testTheDropAcceleratesRatherThanFrontLoadingItsFall() throws {
        let stages = LaunchIntro.Stages(reduceMotion: false)
        let at = { (f: Double) in stages.dropStart + stages.dropFall * f }

        let start = try XCTUnwrap(dropBottomEdge(try render(elapsed: at(0.02))))
        let half = try XCTUnwrap(dropBottomEdge(try render(elapsed: at(0.5))))
        let end = try XCTUnwrap(dropBottomEdge(try render(elapsed: at(1.0))))

        let total = end - start
        XCTAssertGreaterThan(total, 0.01, "the drop should visibly travel downward")

        let coveredByHalfway = (half - start) / total
        // easeInOut is symmetric and covers half the ground in half the time.
        // easeOut covers 87% of it, which is the shape being guarded against.
        XCTAssertLessThan(
            coveredByHalfway, 0.62,
            "halfway through the fall the drop had already covered \(Int(coveredByHalfway * 100))% of the distance — that is a decelerating slide, not a fall"
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
