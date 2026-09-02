#!/usr/bin/env swift
//
// Generates the Current app icon.
//
//   swift Scripts/make-icon.swift            # writes Scripts/AppIcon.iconset + .icns
//
// The icon is drawn in code rather than checked in as a binary so it stays
// editable: change a number here, re-run, and every size regenerates. Each
// size is drawn natively rather than downscaled from 1024, so the thin strokes
// stay crisp at 16pt instead of turning to mush.
//
// The mark: current lines stacked and narrowing as they fall, ending in a
// single drop. Waves are the plain visual language for a current, which is the
// name; the narrowing is many-into-one, which is what a torrent actually does.
// It reads as downward flow without reusing the download arrow already in the
// menu bar.
//
// This went through three literal versions first — tributaries merging into a
// trunk — and every one read as a fork, a stick figure, or antlers. If you are
// tempted to make it more literal again, that is the trap.

import AppKit
import Foundation

// MARK: - Palette

/// Deep and calm on purpose. This app's premise is that torrenting is a
/// background activity, so the icon should not shout from the Dock.
let bgTop = NSColor(srgbRed: 0.137, green: 0.204, blue: 0.494, alpha: 1)   // #23347E
let bgBottom = NSColor(srgbRed: 0.039, green: 0.059, blue: 0.165, alpha: 1) // #0A0F2A

/// The streams. Luminous enough to hold up against both light and dark Docks.
let markTop = NSColor(srgbRed: 0.561, green: 0.949, blue: 1.0, alpha: 1)    // #8FF2FF
let markBottom = NSColor(srgbRed: 0.247, green: 0.663, blue: 1.0, alpha: 1) // #3FA9FF

// MARK: - Geometry helpers

/// Apple's icon shape is a squircle (continuous curvature), not a rounded rect
/// with circular corners. A superellipse at n=5 is a very close match and the
/// difference is visible at 512pt, so it is worth doing properly.
func squirclePath(rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let a = rect.width / 2, b = rect.height / 2
    let cx = rect.midX, cy = rect.midY
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / n), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / n), st)
        if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
    }
    path.closeSubpath()
    return path
}

/// A stream drawn as a *tapering ribbon* rather than a constant-width stroke.
///
/// This matters more than it sounds: uniform strokes read as sticks, and three
/// of them meeting reads as a fork or a stick figure. A ribbon that widens as
/// it descends reads as water gathering, which is both the name and what a
/// torrent actually does — many peers accumulating into one file.
///
/// Walks the cubic Bézier, offsets each sample along the curve normal by half
/// the local width, and closes the two sides into one filled outline.
func ribbon(
    _ p0: CGPoint, _ c1: CGPoint, _ c2: CGPoint, _ p3: CGPoint,
    from w0: CGFloat, to w1: CGFloat, samples: Int = 160
) -> CGPath {
    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = u*u*u*p0.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*p3.x
        let y = u*u*u*p0.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*p3.y
        return CGPoint(x: x, y: y)
    }
    func tangent(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let x = 3*u*u*(c1.x-p0.x) + 6*u*t*(c2.x-c1.x) + 3*t*t*(p3.x-c2.x)
        let y = 3*u*u*(c1.y-p0.y) + 6*u*t*(c2.y-c1.y) + 3*t*t*(p3.y-c2.y)
        return CGPoint(x: x, y: y)
    }

    var left: [CGPoint] = [], right: [CGPoint] = []
    for i in 0...samples {
        let t = CGFloat(i) / CGFloat(samples)
        let p = point(t), d = tangent(t)
        let len = max(sqrt(d.x*d.x + d.y*d.y), 0.0001)
        let n = CGPoint(x: -d.y / len, y: d.x / len)
        let half = (w0 + (w1 - w0) * t) / 2
        left.append(CGPoint(x: p.x + n.x*half, y: p.y + n.y*half))
        right.append(CGPoint(x: p.x - n.x*half, y: p.y - n.y*half))
    }

    let path = CGMutablePath()
    path.move(to: left[0])
    for p in left.dropFirst() { path.addLine(to: p) }
    for p in right.reversed() { path.addLine(to: p) }
    path.closeSubpath()
    return path
}

func gradient(_ from: NSColor, _ to: NSColor) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [from.cgColor, to.cgColor] as CFArray,
        locations: [0, 1]
    )!
}

// MARK: - Drawing

/// All geometry is authored in a 1024 design space and scaled, so the numbers
/// below stay readable no matter which size is being rendered.
func drawIcon(into ctx: CGContext, pixels: CGFloat) {
    let S: CGFloat = 1024
    let k = pixels / S
    ctx.scaleBy(x: k, y: k)

    // Apple's macOS grid: the shape occupies 824 of the 1024 canvas, leaving
    // room for the shadow the system draws around it.
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = squirclePath(rect: plate)

    // Body
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient(bgTop, bgBottom),
        start: CGPoint(x: 512, y: 924),
        end: CGPoint(x: 512, y: 100),
        options: []
    )

    // Soft light from above — keeps the plate from reading as flat paint.
    ctx.drawRadialGradient(
        gradient(NSColor(white: 1, alpha: 0.16), NSColor(white: 1, alpha: 0)),
        startCenter: CGPoint(x: 512, y: 880), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 880), endRadius: 520,
        options: []
    )
    ctx.restoreGState()

    // The mark. Drawn into a transparency layer so the overlapping strokes
    // read as one continuous piece of water rather than stacked lines.
    ctx.saveGState()
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)

    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)

    // Note: CoreGraphics origin is bottom-left, so "down" is decreasing y.
    //
    // Four current lines, stacked and narrowing as they descend. Two ideas in
    // one shape: waves are the plain visual language for a current, and the
    // downward narrowing is the many-into-one that a torrent actually is.
    //
    // Earlier attempts drew this literally — tributaries merging into a trunk —
    // and every version read as a fork, a stick figure, or antlers. Waves have
    // no limbs to misread. The wave is what keeps this from looking like a
    // filter funnel, so don't flatten it.
    let axis: CGFloat = 512

    // Small sizes get their own artwork, not a shrunk copy. At 16pt the four
    // full-size rows land about a pixel apart and antialiasing fuses them into
    // one solid blob — the icon stops being a current and becomes a funnel. So
    // below 32pt: three rows, heavier strokes, much bigger gaps, and a calmer
    // wave, which is the most detail that actually survives.
    let small = pixels <= 32
    let rows: [(y: CGFloat, width: CGFloat, weight: CGFloat)] = small
        ? [
            (y: 720, width: 400, weight: 88),
            (y: 540, width: 268, weight: 84),
            (y: 360, width: 136, weight: 80),
        ]
        : [
            (y: 728, width: 392, weight: 58),
            (y: 618, width: 300, weight: 54),
            (y: 512, width: 208, weight: 50),
            (y: 410, width: 116, weight: 46),
        ]
    let waviness: CGFloat = small ? 0.040 : 0.052
    let drop: (y: CGFloat, size: CGFloat) = small ? (y: 196, size: 104) : (y: 288, size: 78)

    for row in rows {
        // Amplitude scales with the row's width. A constant amplitude makes the
        // short rows near the bottom look frantic rather than calmer, which is
        // backwards: the current should settle as it converges.
        let amplitude = row.width * waviness
        let half = row.width / 2
        ctx.setLineWidth(row.weight)
        var first = true
        // One full period across each line, so every row crests and troughs in
        // the same places and the stack reads as one moving body of water.
        for i in 0...120 {
            let f = CGFloat(i) / 120
            let x = axis - half + row.width * f
            let y = row.y + amplitude * sin(f * 2 * .pi)
            if first { ctx.move(to: CGPoint(x: x, y: y)); first = false }
            else { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()
    }

    // The arrival: one solid drop where the current has narrowed to a single
    // point. This is the "one file" the streams add up to.
    ctx.fillEllipse(in: CGRect(x: axis - drop.size / 2, y: drop.y, width: drop.size, height: drop.size))

    // Tint the whole assembled mark in one pass. The gradient is extended past
    // both ends of the artwork — without the draws-before/after options the
    // round cap fell outside the ramp and rendered plain white.
    ctx.setBlendMode(.sourceIn)
    ctx.drawLinearGradient(
        gradient(markTop, markBottom),
        start: CGPoint(x: 512, y: 830),
        end: CGPoint(x: 512, y: 210),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawIcon(into: ctx, pixels: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// MARK: - Emit

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = scriptDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// (filename base, points) — @2x is rendered natively at double the pixels.
let sizes: [(String, Int)] = [
    ("16x16", 16), ("32x32", 32), ("128x128", 128), ("256x256", 256), ("512x512", 512),
]

for (name, pt) in sizes {
    try render(pixels: pt).write(to: iconset.appendingPathComponent("icon_\(name).png"))
    try render(pixels: pt * 2).write(to: iconset.appendingPathComponent("icon_\(name)@2x.png"))
}

print("Wrote \(iconset.path)")

// Pack it into the .icns the app bundle actually loads, so regenerating the
// icon is one command rather than two easily-forgotten ones.
let icns = scriptDir.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(icns.path)")
