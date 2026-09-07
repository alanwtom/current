#!/usr/bin/env swift
//
// Draws the install window you see when you double-click Current.dmg.
//
//   swift Scripts/make-dmg-window.swift art   <staging-folder>
//   swift Scripts/make-dmg-window.swift store <mounted-volume>
//
// `art` renders the background into <staging-folder>/.background/, so the disk
// image is sized with the artwork already inside it. `store` writes the Finder
// window itself — size, position, icon size, where the two icons sit, which
// picture is behind them — onto a mounted read-write image.
//
// The picture is a seascape at dusk, and the whole thing is built out of `~`,
// `≈`, `-` and `·` in a monospaced font: an empty sky at the top where the two
// icons stand, the last of the light along the horizon, and a sea of wave marks
// receding towards it. Between the app and the Applications folder runs a
// current of the same marks, ending in an arrowhead, which is the app's own
// language doing the job the usual grey arrow does.
//
// **The artwork and the geometry live in one file on purpose.** They are one
// design: the current has to land exactly where Finder puts the two icons, and
// the horizon has to land exactly where Finder draws their names. Split across
// two scripts they drift the first time either is nudged, and the failure is
// silent — the picture still looks fine on its own, it just stops agreeing with
// the window.
//
// ## Why this writes .DS_Store by hand
//
// Every other DMG builder drives Finder over AppleScript to set this up. That
// needs Automation permission, a running Finder, and a pile of `delay`s, and it
// cannot run unattended — the machine that builds the release has to say yes to
// a privacy prompt first. A .DS_Store is a documented file format, so we write
// one. No permissions, no Finder, same result, and it is reproducible: same
// input, same bytes.
//
// The format is a "Buddy" allocator holding one B-tree of records keyed by
// (filename, four-letter code). We need six records: window state and icon
// view options on the volume root, and an icon position for each of the two
// items. See `writeStore` for the layout.
//
// ## Four things Finder does that you would not guess
//
// Every one of these was found by rendering something, mounting it and looking,
// and every one fails silently — the window just comes up wrong, or plain
// white, with nothing written anywhere.
//
// - **The picture is drawn one point per pixel, and nothing else.** Not scaled,
//   not fitted, and no Retina support of any kind: a 1280×904 image is laid out
//   as 1280×904 *points*, so the window shows its top-left corner hugely
//   magnified. Both blessed ways of pairing an @1x and an @2x image in one file
//   — `tiffutil -cathidpicheck`, and a single page tagged 144 dpi — are read
//   back correctly by AppKit and ignored by Finder. So the artwork is 1x, and
//   slightly soft on a Retina display, and there is no lever here to pull.
// - **`backgroundType` is 2 for a picture and 1 for a colour.** With 2 and a
//   picture Finder cannot resolve, it draws neither — not even the colour also
//   stored beside it — so a broken reference looks exactly like a default
//   window. Testing with `1` and a garish red is the quickest way to prove the
//   plist is being read at all.
// - **`backgroundImageAlias` will not take a bookmark.** See `aliasRecord`.
// - **The title bar is 32pt, not 28.** So the artwork is drawn 28pt taller than
//   the window's content and clipped, and nothing important goes near the
//   bottom edge: if the assumption is ever wrong in the other direction, a short
//   picture leaves a strip of Finder's own white along the bottom.

import AppKit
import Foundation

// MARK: - Layout
//
// One source of truth for the geometry, read by both halves of the script.
// Everything is in points, top-left origin, matching Finder's icon view.

enum L {
    /// The window's content area — and so the visible part of the artwork.
    static let content = CGSize(width: 640, height: 424)

    /// Drawn but clipped. See the note at the top of the file.
    static let overdraw: CGFloat = 28

    static var canvas: CGSize {
        CGSize(width: content.width, height: content.height + overdraw)
    }

    /// A Finder window with no toolbar. Only used to turn the content height we
    /// want into the frame height `.DS_Store` stores. **Measured, not assumed:**
    /// the obvious guess is 28, it is 32, and being wrong by four points slides
    /// the whole picture up and leaves a strip of Finder's white along the bottom.
    static let titleBar: CGFloat = 32

    /// Where the window opens, measured from the bottom-left of the screen the
    /// way Finder stores it. Small enough to fit any display; Finder pushes the
    /// window back on screen if it has to.
    static let windowOrigin = CGPoint(x: 320, y: 220)

    static let iconSize: CGFloat = 112
    static let textSize: CGFloat = 12

    /// The two icons, and the line the current runs along between them. Finder
    /// centres the icon *image* on these, with the name below.
    static let app = CGPoint(x: 168, y: 186)
    static let drop = CGPoint(x: 472, y: 186)
    static var waterline: CGFloat { app.y }

    /// Where Finder writes the two names — measured off a render, not guessed:
    /// the text lands at y 256–268 for a 112pt icon at 12pt text. Wave marks are
    /// held back here so the names have something quiet to sit on.
    static let labelBand: CGFloat = 262
    static let labelHeight: CGFloat = 30
    static let labelWidth: CGFloat = 154

    /// The two lines of words, down on the wet sand where the tone is dark
    /// enough for light grey text.
    static let captionTop: CGFloat = 368
    static let captionBottom: CGFloat = 392

    /// The horizon: sky above it, water below, and the brightest tone in the
    /// picture along it.
    ///
    /// **This is placed by the item names, not by taste.** It has to be light
    /// where Finder writes them and dark everywhere the picture's own words are,
    /// so it sits on `labelBand` and the glow is wide enough to cover the whole
    /// height of the text. Everything else in the composition follows from that
    /// one constraint — which is the useful kind of constraint, because a
    /// horizon is the one thing that is *allowed* to be the brightest line in a
    /// seascape.
    static let horizon: CGFloat = 260
    static let glowWidth: CGFloat = 74

    /// How lit the water or sky is at a given height: 1 along the horizon,
    /// falling away above and below. Wave marks read their colour off this, so
    /// ripples go dark on the lit water and pale out in the dark.
    static func litness(_ y: CGFloat, driftedBy drift: CGFloat = 0) -> CGFloat {
        bell(y, horizon + drift, glowWidth)
    }

    /// Sky at the top, the glow at the horizon, water darkening to the bottom.
    static let seascape: CGGradient = {
        let stops: [(y: CGFloat, colour: NSColor)] = [
            (0, P.skyTop),
            (168, P.skyMid),
            (243, P.skyHorizon),
            (259, P.glow),
            (286, P.waterLit),
            (350, P.waterDeep),
            (452, P.waterFloor),
        ]
        let height = stops.last!.y
        return CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: stops.map { $0.colour.cgColor } as CFArray,
            locations: stops.map { $0.y / height }
        )!
    }()
}

// MARK: - Palette
//
// The same colours as the app icon and the website: deep blue ink, one accent.
// The sea is grey-blue and stays that way — in this app colour identifies
// something rather than decorating it, so the only coloured things in here are
// the current and the drop target, and they are saying the same sentence.

enum P {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a
        )
    }

    // Dusk, top to bottom: night sky, the last of the light on the horizon,
    // then water getting darker as it comes towards you.
    static let skyTop = rgb(0x04060E)
    static let skyMid = rgb(0x0C1428)
    static let skyHorizon = rgb(0x3E4E71)
    static let glow = rgb(0x717F98)      // the horizon itself — see L.horizon
    static let waterLit = rgb(0x475677)
    static let waterDeep = rgb(0x111A31)
    static let waterFloor = rgb(0x05080F)

    static let foam = rgb(0xC6D4EC)      // wave marks on the dark water
    static let ripple = rgb(0x16203A)    // and the same marks on the lit water
    static let accent = rgb(0x3FA9FF)    // the current, and the drop target
    static let captionStrong = rgb(0xC2CBDD)
    static let captionQuiet = rgb(0x77839C)
}

// MARK: - Small helpers

/// Deterministic, so re-running the script produces the same picture. A picture
/// that reshuffles every build makes a one-line change look like a redesign.
struct RNG {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed }
    mutating func next() -> UInt64 {
        s = s &* 6364136223846793005 &+ 1442695040888963407
        return s >> 11
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 100_000) / 100_000 }
    mutating func int(_ n: Int) -> Int { n <= 0 ? 0 : Int(next() % UInt64(n)) }
    mutating func pick<T>(_ xs: [T]) -> T { xs[int(xs.count)] }
}

func bell(_ x: CGFloat, _ centre: CGFloat, _ width: CGFloat) -> CGFloat {
    let t = (x - centre) / width
    return exp(-t * t)
}

func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

func radial(_ colour: NSColor, _ peak: CGFloat) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [colour.withAlphaComponent(peak).cgColor, colour.withAlphaComponent(0).cgColor] as CFArray,
        locations: [0, 1]
    )!
}

// MARK: - Text

func draw(
    _ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
    colour: NSColor, at p: CGPoint, tracking: CGFloat = 0, mono: Bool = false
) {
    let font = mono
        ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        : NSFont.systemFont(ofSize: size, weight: weight)
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
    if tracking != 0 { attrs[.kern] = tracking }
    let s = NSAttributedString(string: string, attributes: attrs)
    let box = s.size()
    s.draw(at: CGPoint(x: p.x - box.width / 2, y: p.y - box.height / 2))
}

/// The sea is drawn one character at a time, so each mark needs to land with its
/// *ink* centred on the wave row — not its line box, which is mostly air above a
/// tilde. This nudge is that difference, as a fraction of the font size, and it
/// was set by looking at a render rather than by reading a font metric.
let inkNudge: CGFloat = 0.30

func drawMark(_ ch: String, size: CGFloat, colour: NSColor, centre: CGPoint) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let s = NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: colour])
    let box = s.size()
    s.draw(at: CGPoint(x: centre.x - box.width / 2, y: centre.y - box.height / 2 + size * inkNudge))
    return box.width
}

// MARK: - The picture

/// How far the horizon has wandered from dead straight at a given x.
///
/// Two slow sines beating against each other. A ruler-straight line of light
/// reads as a design element someone left in; a wandering one reads as water,
/// and it costs one line.
func horizonDrift(_ x: CGFloat) -> CGFloat {
    5 * sin(x / 176 + 0.7) + 2.5 * sin(x / 63)
}

func drawBackground(into ctx: CGContext) {
    let W = L.canvas.width, H = L.canvas.height

    // ----------------------------------------------------------- the seascape
    //
    // Night sky at the top, the last of the light along the horizon, water
    // getting darker as it comes towards you. Drawn in narrow vertical slices so
    // the horizon can wander with `horizonDrift` rather than lying flat.
    //
    // **The tone along the horizon is calculated, not picked.** It is the one
    // part of this picture with a correct answer: Finder draws the two item
    // names in the system text colour — black in Light Mode, white in Dark —
    // straight over whatever is here, and we get no say in it. One tone has to
    // work against both, and the best any tone can do is where the two contrast
    // ratios meet: (L+0.05)/0.05 = 1.05/(L+0.05), so L = 0.179 and both come out
    // at 4.6:1. `P.glow` is tuned so the pixels under the two names measure
    // 0.17–0.19, which lands every name in both appearances at 4.4:1 or better.
    //
    // Lighten it and Dark Mode loses the names; darken it and Light Mode does.
    // Nothing tests this, so if you touch `P.glow`, re-render and measure the
    // pixels where the names actually land.
    let slice: CGFloat = 2
    var bx: CGFloat = 0
    while bx < W {
        ctx.saveGState()
        ctx.clip(to: CGRect(x: bx, y: 0, width: slice, height: H))
        let drift = horizonDrift(bx + slice / 2)
        ctx.drawLinearGradient(
            L.seascape,
            start: CGPoint(x: 0, y: drift),
            end: CGPoint(x: 0, y: H + drift),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        ctx.restoreGState()
        bx += slice
    }

    // Two glows, one behind each icon. The app's is the light it is standing in
    // front of: both it and the sky behind it are deep navy, and without this
    // its top half half disappears. The folder's is accent, because that is the
    // colour this app uses for the place a thing is going.
    for (centre, colour, peak, radius) in [
        (L.app, P.skyHorizon, CGFloat(0.30), CGFloat(122)),
        (L.drop, P.accent, CGFloat(0.22), CGFloat(116)),
    ] {
        ctx.saveGState()
        ctx.translateBy(x: centre.x, y: centre.y + 4)
        ctx.scaleBy(x: 1, y: 0.82)
        ctx.drawRadialGradient(
            radial(colour, peak),
            startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: []
        )
        ctx.restoreGState()
    }

    // -------------------------------------------------------------- the sea
    //
    // Everything below the horizon, in perspective: at the horizon the marks are
    // tiny and packed together, and they grow and spread as the water comes
    // forward. The row *spacing* is what does the work — evenly spaced rows read
    // as a pattern, geometrically spaced ones read as distance. The sky above
    // stays empty on purpose; the icons and the current are up there, and they
    // need the quiet.
    //
    // Each mark takes its colour from how lit the water is under it: dark
    // ripples on the bright water near the horizon, pale foam out on the dark
    // water below. Everything in one colour flattened the whole sea into a
    // texture; the inversion is what gives it depth.
    var rng = RNG(0x0C17_7E17)
    var rows: [(y: CGFloat, size: CGFloat)] = []
    var y: CGFloat = L.horizon + 3
    var gap: CGFloat = 3.4
    while y < H + 24 {
        rows.append((y: y, size: min(gap * 2.1, 26)))
        y += gap
        gap *= 1.155
    }

    for row in rows {
        // Nearly nothing at the horizon, then ripples, then loose water.
        let near = smoothstep(L.horizon, H, row.y)
        let glyphs: [String] = near < 0.16
            ? ["-", "~", "-", "-", "~", "-"]
            : (near < 0.52 ? ["~", "~", "≈", "~", "-", "~"] : ["~", "~", "·", "~", "≈", "~"])

        let amp = min(row.size * 0.22, 6)
        let wavelength = 120 + rng.unit() * 140
        let phase = rng.unit() * .pi * 2

        var x = -30 - rng.unit() * 50
        while x < W + 40 {
            let advance = row.size * 0.60
            // Runs, not scatter. Single marks with gaps between them read as
            // noise; a run of them reads as the crest of something.
            let run = 2 + rng.int(6)
            // Each run rides a little above or below its row, so the sea does
            // not lay itself out in visible courses like brickwork.
            let jitter = (rng.unit() - 0.5) * min(row.size * 0.30, 5)
            for _ in 0..<run {
                let yy = row.y + jitter + amp * sin(x / wavelength * .pi * 2 + phase)
                let lit = L.litness(yy, driftedBy: horizonDrift(x))

                var a = (0.14 + 0.22 * (1 - lit)) * (0.78 + 0.22 * rng.unit())
                // Quiet at the edges, so the sea doesn't collide with the
                // window frame, and quiet as the water reaches the bottom.
                a *= 0.62 + 0.38 * bell(x, W / 2, 340)
                a *= 1 - smoothstep(L.content.height - 64, L.content.height + 6, row.y)

                // Hold back where Finder will draw the two item names, and
                // across the water the picture's own words sit on. Both
                // clearings fade rather than stop: a hard-edged one leaves a
                // visible empty rectangle in the middle of the sea.
                for centre in [L.app.x, L.drop.x] {
                    let near = bell(x, centre, L.labelWidth / 2) * bell(yy, L.labelBand, L.labelHeight)
                    a *= 1 - 0.90 * near
                }
                let words = max(bell(yy, L.captionTop, 20), bell(yy, L.captionBottom, 20))
                a *= 1 - 0.88 * words

                if a > 0.012 {
                    let colour = lit > 0.5
                        ? P.ripple.withAlphaComponent(a * lit)
                        : P.foam.withAlphaComponent(a * (1 - lit * 0.8))
                    _ = drawMark(
                        rng.pick(glyphs), size: row.size, colour: colour,
                        centre: CGPoint(x: x, y: yy)
                    )
                }
                x += advance
            }
            x += advance * CGFloat(1 + rng.int(2))
        }
    }

    // ------------------------------------------------------------- the sky
    //
    // Long, flat, very faint runs of dashes up where there is nothing else.
    // The top third of the window is sky the icons stand against, and it wants
    // texture rather than incident — anything with contrast up here competes
    // with the one thing this window is asking someone to do.
    var cloud = RNG(0xC10D_5)
    for band in 0..<5 {
        let cy = 34 + CGFloat(band) * 22 + cloud.unit() * 8
        var kx = -40 - cloud.unit() * 80
        while kx < W + 40 {
            let size: CGFloat = 13 + cloud.unit() * 5
            let advance = size * 0.60
            let run = 6 + cloud.int(16)
            for _ in 0..<run {
                var a = 0.07 * (0.5 + 0.5 * cloud.unit())
                a *= 0.35 + 0.65 * bell(kx, W / 2 + 60, 300)
                _ = drawMark(
                    cloud.unit() < 0.25 ? "~" : "-", size: size,
                    colour: P.foam.withAlphaComponent(a),
                    centre: CGPoint(x: kx, y: cy)
                )
                kx += advance
            }
            kx += advance * CGFloat(2 + cloud.int(6))
        }
    }

    // ---------------------------------------------------------- the current
    //
    // The one thing in the window that is trying to say something: a run of
    // wave marks flowing out of the app and into the folder, brightening as it
    // arrives. It is the app's own language for "this is happening" — the icon
    // is four of these stacked — doing the job the usual big grey arrow does.
    let streamStart = L.app.x + L.iconSize / 2 + 16
    let streamEnd = L.drop.x - L.iconSize / 2 - 22
    var cx = streamStart
    var stream = RNG(0x57_2EAA)
    while cx < streamEnd {
        let t = (cx - streamStart) / (streamEnd - streamStart)
        let size: CGFloat = 19
        let yy = L.waterline + sin(t * .pi * 2.2) * 3.4
        let a = 0.30 + 0.55 * t
        let w = drawMark(
            stream.unit() < 0.22 ? "≈" : "~", size: size,
            colour: P.accent.withAlphaComponent(a),
            centre: CGPoint(x: cx, y: yy)
        )
        cx += w * 1.02
    }
    // It arrives as an arrowhead, because at this point the picture should stop
    // being poetic and start being an instruction.
    _ = drawMark(">", size: 23, colour: P.accent.withAlphaComponent(0.92),
                 centre: CGPoint(x: streamEnd + 6, y: L.waterline))

    // ------------------------------------------------------- the drop target
    //
    // Accent light pooling around the folder, because in this app accent means
    // "this is happening, or this is where it goes". The first version of this
    // was the dashed rounded box every installer draws; against soft water it
    // read as a stray rectangle someone forgot to delete, and the arrow was
    // already doing the pointing.

    // ------------------------------------------------------------- the ruler
    //
    // `DMG_RULER=1` overlays a 40pt grid with its coordinates, which is how
    // every measured number in `L` was arrived at. Off in a release.
    if ProcessInfo.processInfo.environment["DMG_RULER"] != nil {
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [])
        for gx in stride(from: 0, through: Int(W), by: 40) {
            ctx.move(to: CGPoint(x: CGFloat(gx), y: 0)); ctx.addLine(to: CGPoint(x: CGFloat(gx), y: H)); ctx.strokePath()
            draw("\(gx)", size: 9, colour: .systemRed, at: CGPoint(x: CGFloat(gx) + 12, y: 10))
        }
        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        for gy in stride(from: 0, through: Int(H), by: 40) {
            ctx.move(to: CGPoint(x: 0, y: CGFloat(gy))); ctx.addLine(to: CGPoint(x: W, y: CGFloat(gy))); ctx.strokePath()
            draw("\(gy)", size: 9, colour: .systemGreen, at: CGPoint(x: 16, y: CGFloat(gy) + 10))
        }
    }
    // ------------------------------------------------------------- the words
    //
    // Two lines: what to do, then the one thing people get wrong. Running the
    // app from the disk image works well enough to look fine and quietly breaks
    // updates, because Sparkle cannot write to a read-only volume — so it is
    // worth a sentence here rather than a support email later.
    draw(
        "DRAG CURRENT INTO APPLICATIONS", size: 11, weight: .semibold,
        colour: P.captionStrong, at: CGPoint(x: L.content.width / 2, y: L.captionTop), tracking: 1.9
    )
    draw(
        "Then eject the disk — Current can't update itself from here.", size: 11.5,
        colour: P.captionQuiet, at: CGPoint(x: L.content.width / 2, y: L.captionBottom)
    )
}

// MARK: - Rendering

func render(scale: CGFloat) -> NSBitmapImageRep {
    let px = (w: Int(L.canvas.width * scale), h: Int(L.canvas.height * scale))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px.w, pixelsHigh: px.h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Points, not pixels, and reported to AppKit as such, so the @2x rep pairs
    // with the @1x one in a single TIFF instead of being a second picture.
    rep.size = L.canvas

    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = nsCtx.cgContext

    // Flip into a top-left origin, which is how Finder thinks about the icon
    // view and therefore how every number in `L` is written. `flipped: true`
    // is what keeps AppKit drawing the text right side up in it.
    ctx.translateBy(x: 0, y: CGFloat(px.h))
    ctx.scaleBy(x: scale, y: -scale)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    drawBackground(into: ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writeArt(to staging: String) throws {
    let dir = URL(fileURLWithPath: staging).appendingPathComponent(".background")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    // One size, 1x, and slightly soft on a Retina display. That is not an
    // oversight and there is no fix for it — see the note at the top of the
    // file: Finder draws this picture one point per pixel and ignores both
    // documented ways of pairing an @1x and an @2x image in one file. A
    // two-page TIFF here doesn't get you a sharp window, it gets you the
    // top-left quarter of the artwork at four times the size.
    let art = render(scale: 1)
    let out = dir.appendingPathComponent("background.tiff")
    try art.representation(using: .tiff, properties: [:])!.write(to: out)

    // Cheap proof the picture comes back at the size the geometry assumes, so
    // a canvas change that AppKit quietly rounds can't slide the whole window.
    guard let check = NSImage(contentsOf: out), check.size == L.canvas
    else { throw Err("the TIFF came back \(NSImage(contentsOf: out)?.size.debugDescription ?? "unreadable"), not \(L.canvas)") }

    print("  background \(Int(L.canvas.width))×\(Int(L.canvas.height)) @1x → \(out.path)")
}

// MARK: - The Finder window (.DS_Store)

struct Err: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// One record in the store's B-tree: an item name, a four-letter key, and a value.
struct Record {
    enum Value {
        case bool(Bool)
        case long(UInt32)
        case blob([UInt8])
        case string(String)
    }
    let name: String
    let code: String
    let value: Value

    var bytes: [UInt8] {
        var out: [UInt8] = []
        let utf16 = Array(name.utf16)
        out += be32(UInt32(utf16.count))
        for unit in utf16 { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        out += Array(code.utf8)
        switch value {
        case .bool(let b):
            out += Array("bool".utf8); out += [b ? 1 : 0]
        case .long(let v):
            out += Array("long".utf8); out += be32(v)
        case .blob(let data):
            out += Array("blob".utf8); out += be32(UInt32(data.count)); out += data
        case .string(let s):
            let u = Array(s.utf16)
            out += Array("ustr".utf8); out += be32(UInt32(u.count))
            for unit in u { out += [UInt8(unit >> 8), UInt8(unit & 0xFF)] }
        }
        return out
    }
}

func be32(_ v: UInt32) -> [UInt8] {
    [UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]
}

func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

func be64(_ v: UInt64) -> [UInt8] {
    (0..<8).reversed().map { UInt8((v >> (8 * UInt64($0))) & 0xFF) }
}

/// A Pascal string — one length byte, then the bytes, padded out to a fixed field.
func pascal(_ s: String, field: Int) -> [UInt8] {
    var bytes = Array(s.utf8.prefix(field - 1))
    var out: [UInt8] = [UInt8(bytes.count)]
    out += bytes
    bytes = []
    while out.count < field { out.append(0) }
    return out
}

/// Seconds since 1904, which is how an alias record states a date.
func macTime(_ date: Date?) -> UInt32 {
    guard let date else { return 0 }
    return UInt32(clamping: Int(date.timeIntervalSince1970) + 2_082_844_800)
}

/// Builds the reference Finder wants for the background picture.
///
/// **A modern bookmark does not work here.** `URL.bookmarkData()` is the obvious
/// thing to reach for, it produces a blob Finder happily stores, and the window
/// then comes up plain white with no error anywhere — the field wants the
/// pre-10.6 Carbon *alias record*, which has had no public API for fifteen years.
/// So this writes one: a 150-byte header naming the volume and the file, then
/// tagged extras (the two paths and the Unicode names are what actually resolve
/// it), terminated by tag -1.
///
/// It is built against the mounted staging image, and it keeps working after the
/// image is converted and mounted on someone else's Mac because everything in it
/// — volume name, file id, both paths — is unchanged by `hdiutil convert`.
func aliasRecord(for fileURL: URL) throws -> Data {
    let parentURL = fileURL.deletingLastPathComponent()

    var fileStat = stat(), parentStat = stat()
    guard stat(fileURL.path, &fileStat) == 0, stat(parentURL.path, &parentStat) == 0 else {
        throw Err("cannot stat \(fileURL.path)")
    }

    let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeCreationDateKey, .volumeURLKey, .creationDateKey]
    let values = try fileURL.resourceValues(forKeys: keys)
    guard let volumeName = values.volumeName, let mountPoint = values.volume else {
        throw Err("cannot read the volume \(fileURL.path) lives on")
    }

    let fileName = fileURL.lastPathComponent
    let carbonPath = "\(volumeName):\(parentURL.lastPathComponent):\(fileName)"

    // --- the fixed 150-byte header
    var header: [UInt8] = []
    header += be32(0)                                  // application info, unused
    header += be16(0)                                  // record size, filled in below
    header += be16(2)                                  // version 2
    header += be16(0)                                  // kind: 0 is a file
    header += pascal(volumeName, field: 28)
    header += be32(macTime(values.volumeCreationDate))
    header += Array("H+".utf8)                         // HFS+ signature
    header += be16(0)                                  // fixed disk, which a mounted image counts as
    header += be32(UInt32(parentStat.st_ino))          // parent folder id
    header += pascal(fileName, field: 64)
    header += be32(UInt32(fileStat.st_ino))            // file id
    header += be32(macTime(values.creationDate))
    header += be32(0)                                  // file type, unset
    header += be32(0)                                  // creator, unset
    header += be16(0xFFFF)                             // depth from — unknown
    header += be16(0xFFFF)                             // depth to — unknown
    header += be32(0)                                  // volume attributes
    header += be16(0)                                  // volume filesystem id
    header += [UInt8](repeating: 0, count: 10)         // reserved
    precondition(header.count == 150)

    // --- the tagged extras
    var tags: [UInt8] = []
    func tag(_ id: UInt16, _ data: [UInt8]) {
        tags += be16(id) + be16(UInt16(data.count)) + data
        if data.count % 2 == 1 { tags += [0] }         // every tag lands on an even boundary
    }
    func utf16Tag(_ id: UInt16, _ s: String) {
        let units = Array(s.utf16)
        var data = be16(UInt16(units.count))
        for u in units { data += be16(u) }
        tag(id, data)
    }

    tag(0, Array(parentURL.lastPathComponent.utf8))                      // parent folder name
    tag(1, be32(UInt32(parentStat.st_ino)))                              // folder ids down to it
    tag(2, Array(carbonPath.utf8))                                       // Volume:folder:file
    utf16Tag(14, fileName)
    utf16Tag(15, volumeName)
    tag(16, be64(UInt64(macTime(values.volumeCreationDate)) << 16))      // the same dates, finer
    tag(17, be64(UInt64(macTime(values.creationDate)) << 16))
    tag(18, Array(fileURL.path.utf8))
    tag(19, Array(mountPoint.path.utf8))
    tags += be16(0xFFFF) + be16(0)                                       // end of tags

    var record = header + tags
    let size = UInt16(record.count)
    record[4] = UInt8(size >> 8)
    record[5] = UInt8(size & 0xFF)
    return Data(record)
}

func plist(_ dict: [String: Any]) throws -> [UInt8] {
    let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .binary, options: 0)
    return Array(data)
}

/// Icon position. 16 bytes: x, y, then two half-words Finder leaves at 0xFFFF
/// and a trailing zero. The position is the centre of the item's cell.
func iloc(_ p: CGPoint) -> [UInt8] {
    be32(UInt32(p.x)) + be32(UInt32(p.y)) + [0xFF, 0xFF, 0xFF, 0xFF] + be32(0)
}

func writeStore(volume: String, appName: String) throws {
    let vol = URL(fileURLWithPath: volume)
    let background = vol.appendingPathComponent(".background/background.tiff")
    guard FileManager.default.fileExists(atPath: background.path) else {
        throw Err("no .background/background.tiff on \(volume) — run the `art` step first")
    }

    // Finder stores a reference to the picture, not the picture itself.
    let alias = try aliasRecord(for: background)

    let frame = CGRect(
        x: L.windowOrigin.x, y: L.windowOrigin.y,
        width: L.content.width, height: L.content.height + L.titleBar
    )
    let windowState: [String: Any] = [
        "WindowBounds": "{{\(Int(frame.minX)), \(Int(frame.minY))}, {\(Int(frame.width)), \(Int(frame.height))}}",
        "ShowSidebar": false,
        "ShowToolbar": false,
        "ShowStatusBar": false,
        "ShowPathbar": false,
        "ShowTabView": false,
        "SidebarWidth": 0,
    ]
    let iconView: [String: Any] = [
        "viewOptionsVersion": 1,
        "backgroundType": 2,
        "backgroundImageAlias": alias,
        "backgroundColorRed": 1.0,
        "backgroundColorGreen": 1.0,
        "backgroundColorBlue": 1.0,
        "gridOffsetX": 0.0,
        "gridOffsetY": 0.0,
        "gridSpacing": 100.0,
        "iconSize": Double(L.iconSize),
        "textSize": Double(L.textSize),
        "labelOnBottom": true,
        "showIconPreview": false,
        "showItemInfo": false,
        "arrangeBy": "none",
    ]

    let records: [Record] = [
        Record(name: ".", code: "ICVO", value: .bool(true)),
        Record(name: ".", code: "bwsp", value: .blob(try plist(windowState))),
        Record(name: ".", code: "icvp", value: .blob(try plist(iconView))),
        Record(name: ".", code: "vSrn", value: .long(1)),
        Record(name: appName, code: "Iloc", value: .blob(iloc(L.app))),
        Record(name: "Applications", code: "Iloc", value: .blob(iloc(L.drop))),
    ]

    try writeBuddyStore(records: records, to: vol.appendingPathComponent(".DS_Store"))
    print("  window \(Int(frame.width))×\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY)) → \(volume)/.DS_Store")
}

/// Packs the records into the on-disk format.
///
/// The file is a block allocator with a 36-byte header; every address it stores
/// is relative to offset 4, which is why the first block sits at address 0x20.
/// Inside it, a directory named "DSDB" points at a master block, which points at
/// the tree. Our handful of records fits in one leaf, so there is no tree to
/// balance.
///
/// **The shape below was copied from a file Finder wrote, not from a spec.** Two
/// of the details are not what you would guess, and getting either wrong makes
/// the whole file get ignored in silence: `levels` is 0 when the root node *is*
/// the leaf, and the bookkeeping block registers itself in its own table as
/// block 0, so the master and the leaf are blocks 1 and 2. Finder also sizes a
/// node block to its contents and leaves `pageSize` at 4096 regardless — those
/// two numbers have nothing to do with each other.
///
/// Records must be sorted by item name lowercased, then by raw key bytes. Finder
/// binary-searches this; out of order, it simply doesn't find `icvp` and you get
/// a plain white window with no error anywhere.
func writeBuddyStore(records: [Record], to url: URL) throws {
    let sorted = records.sorted { a, b in
        let an = a.name.lowercased(), bn = b.name.lowercased()
        if an != bn { return an < bn }
        return Array(a.code.utf8).lexicographicallyPrecedes(Array(b.code.utf8))
    }

    // --- the leaf node: no children, then the records back to back
    var node: [UInt8] = be32(0) + be32(UInt32(sorted.count))
    for r in sorted { node += r.bytes }

    func blockSize(_ needed: Int) -> Int {
        var size = 32
        while size < needed { size <<= 1 }
        return size
    }
    let nodeSize = blockSize(node.count)

    // --- the master block: which block holds the tree, and how big it is
    let master: [UInt8] =
        be32(2)                       // the root node is block 2
        + be32(0)                     // nothing below it — the root is the leaf
        + be32(UInt32(sorted.count))
        + be32(1)                     // one node
        + be32(0x1000)                // page size, unrelated to the block above

    // Blocks are aligned to their own size, which is what "buddy" means, and the
    // bookkeeping block sits past everything else.
    let masterAddr = 0x20
    let nodeAddr = max(nodeSize, 0x40)
    let bookSize = 0x800
    let bookAddr = max(nodeAddr + nodeSize, 0x1000)

    let blocks: [(addr: Int, size: Int, data: [UInt8])] = [
        (masterAddr, 32, master),
        (nodeAddr, nodeSize, node),
    ]

    // --- the bookkeeping block: the block table, the directory, the free lists
    let table: [(addr: Int, size: Int)] = [
        (bookAddr, bookSize),    // block 0 — this block
        (masterAddr, 32),        // block 1 — the master
        (nodeAddr, nodeSize),    // block 2 — the leaf
    ]
    var book: [UInt8] = be32(UInt32(table.count)) + be32(0)
    for b in table {
        var k = 5
        while (1 << k) < b.size { k += 1 }
        book += be32(UInt32(b.addr | k))   // the size lives in the low 5 bits
    }
    // The table is written in whole runs of 256 entries.
    let padded = ((table.count + 255) / 256) * 256
    for _ in table.count..<padded { book += be32(0) }
    book += be32(1)                                     // one directory
    book += [UInt8("DSDB".utf8.count)] + Array("DSDB".utf8) + be32(1)
    for _ in 0..<32 { book += be32(0) }                 // nothing free to reuse
    precondition(book.count <= bookSize)

    // --- and the header
    var file = [UInt8]()
    file += be32(1)
    file += Array("Bud1".utf8)
    file += be32(UInt32(bookAddr))
    file += be32(UInt32(bookSize))
    file += be32(UInt32(bookAddr))
    file += [UInt8](repeating: 0, count: 16)
    precondition(file.count == 36)

    func place(_ data: [UInt8], at addr: Int, size: Int) {
        let start = addr + 4
        if file.count < start + size { file += [UInt8](repeating: 0, count: start + size - file.count) }
        file.replaceSubrange(start..<(start + data.count), with: data)
    }
    for b in blocks { place(b.data, at: b.addr, size: b.size) }
    place(book, at: bookAddr, size: bookSize)

    try Data(file).write(to: url)
}

/// Gives the mounted volume the app's own icon, so the disk in the sidebar and
/// on the desktop isn't a generic grey drive. The custom-icon flag lives in the
/// Finder info bits; the 0x0400 is that flag.
func setVolumeIcon(volume: String, icns: String) throws {
    guard FileManager.default.fileExists(atPath: icns) else { return }
    let dest = volume + "/.VolumeIcon.icns"
    try? FileManager.default.removeItem(atPath: dest)
    try FileManager.default.copyItem(atPath: icns, toPath: dest)

    var info = [UInt8](repeating: 0, count: 32)
    info[8] = 0x04
    let ok = info.withUnsafeBytes { buf in
        setxattr(volume, "com.apple.FinderInfo", buf.baseAddress, buf.count, 0, 0) == 0
    }
    if !ok { print("  (could not set the custom volume icon — cosmetic, carrying on)") }
    print("  volume icon → \(dest)")
}

// MARK: - Entry

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("""
        usage:
          make-dmg-window.swift art   <staging-folder>
          make-dmg-window.swift store <mounted-volume> [app-name]

        """.utf8))
    exit(2)
}

do {
    switch args[0] {
    case "art":
        try writeArt(to: args[1])
    case "store":
        let appName = args.count > 2 ? args[2] : "Current.app"
        try writeStore(volume: args[1], appName: appName)
        let icns = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("AppIcon.icns").path
        try setVolumeIcon(volume: args[1], icns: icns)
    default:
        throw Err("unknown step \(args[0]) — expected `art` or `store`")
    }
} catch {
    FileHandle.standardError.write(Data("make-dmg-window: \(error)\n".utf8))
    exit(1)
}
