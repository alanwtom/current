#!/usr/bin/env swift
//
// Draws the install window you see when you double-click Current.dmg.
//
//   swift Scripts/make-dmg-window.swift art   <staging-folder>
//   swift Scripts/make-dmg-window.swift store <mounted-volume>
//
// `art` renders the picture into <staging-folder>/.background/, so the disk
// image is sized with it already inside. `store` writes the Finder window
// itself — size, position, icon size, where the two icons sit, which picture is
// behind them — onto a mounted read-write image.
//
// **The picture is one thing: a current running from the app into the
// Applications folder.** A run of `~` and `≈` marks in accent blue, ending in
// an arrowhead — the app's own language for "this is happening", doing the job
// the usual big grey arrow does. Everything else is transparent, so the window
// is Finder's own: its background, its item names, in whichever appearance the
// machine is set to.
//
// It used to be a full seascape at dusk with the two icons standing against the
// sky and two lines of instructions along the bottom. That is gone deliberately,
// and one thing went with it worth knowing about: a line saying to eject the
// disk after dragging, because **an app run from inside the image looks
// completely fine and silently cannot ever update itself** — Sparkle can't write
// to a read-only volume. Nothing warns about that now. If it ever turns into a
// support question, that is the answer, and the window is where it used to be
// said.
//
// Losing the artwork also removed the hardest constraint in here. Finder draws
// the item names in the system text colour — black in Light Mode, white in Dark
// — straight over the background, and we get no say in it, so a picture behind
// them had to hit one tone that both could be read against. On transparency the
// problem doesn't exist: the names sit on Finder's own background, which is
// already the right colour for the appearance it's in.
//
// **The picture and the geometry still live in one file on purpose.** The
// current has to start and end exactly where Finder puts the two icons, and the
// failure is silent if they drift — the arrow still looks fine on its own, it
// just stops pointing at anything.
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
// ## Five things Finder does that you would not guess
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
// - **Transparency composites over Finder's own background,** which is what lets
//   the picture be one arrow and nothing else. Worth stating because the
//   plausible alternative — Finder flattening the image onto white — would look
//   correct in Light Mode and put a white slab behind the icons in Dark, and
//   whoever changes this next will be running in one appearance or the other.
// - **`backgroundType` is 2 for a picture and 1 for a colour.** With 2 and a
//   picture Finder cannot resolve, it draws neither — not even the colour also
//   stored beside it — so a broken reference looks exactly like a default
//   window. Since the picture is now *mostly* transparent, a resolve failure and
//   a success look far more alike than they used to: the tell is the arrow.
// - **`backgroundImageAlias` will not take a bookmark.** See `aliasRecord`.
// - **The image's top-left corner is the top-left of the window's *content*,**
//   under the title bar rather than behind it — so a y in the picture is the same
//   y Finder puts an icon at, which is why `L` has one set of numbers for both.
//   It is drawn a little taller than the content and clipped, out of caution
//   rather than need now that the bottom of it is empty.

import AppKit
import Foundation

// MARK: - Layout
//
// One source of truth for the geometry, read by both halves of the script.
// Everything is in points, top-left origin, matching Finder's icon view.

enum L {
    /// The window's content area — and so the visible part of the picture.
    ///
    /// **Sized to the two icons and nothing else**, now that there is nothing
    /// else. It was 424 tall to make room for a seascape and two lines of
    /// instructions below the icons; with those gone the same window was two
    /// thirds empty, which reads as a layout that failed rather than a spare
    /// one. The icons and their names are vertically centred in what's left.
    static let content = CGSize(width: 640, height: 300)

    /// Drawn but clipped. See the note at the top of the file.
    static let overdraw: CGFloat = 28

    static var canvas: CGSize {
        CGSize(width: content.width, height: content.height + overdraw)
    }

    /// A Finder window with no toolbar. Only used to turn the content height we
    /// want into the frame height `.DS_Store` stores. **Measured, not assumed:**
    /// the obvious guess is 28, it is 32, and being wrong by four points slides
    /// the whole picture relative to the icons Finder places over it.
    static let titleBar: CGFloat = 32

    /// Where the window opens, measured from the bottom-left of the screen the
    /// way Finder stores it. Small enough to fit any display; Finder pushes the
    /// window back on screen if it has to.
    static let windowOrigin = CGPoint(x: 320, y: 220)

    static let iconSize: CGFloat = 112
    static let textSize: CGFloat = 12

    /// The two icons, and the line the current runs along between them. Finder
    /// centres the icon *image* on these, with the name below.
    ///
    /// The y is what centres the pair in the window: an icon and its name
    /// together stand about 138pt tall, so in a 300pt window the block starts at
    /// 81 and the icon's middle lands 56 below that. Change `content.height` and
    /// this has to move with it, or the two icons sit high in an empty window.
    static let app = CGPoint(x: 168, y: 137)
    static let drop = CGPoint(x: 472, y: 137)

    /// The height the current runs along — the icons' own middle, so it comes
    /// out of one and into the other rather than passing under them.
    static var waterline: CGFloat { app.y }
}

// MARK: - Palette
//
// One colour. In this app accent means "this is happening, or this is where it
// goes", which is exactly what the arrow is saying, and there is nothing else in
// the picture to give a colour to.
//
// It has to work on Finder's background in *both* appearances — near-white in
// Light Mode, near-black in Dark — which a mid-tone saturated blue does and a
// pale or a dark one wouldn't. This is the app's accent unchanged, which is the
// reason it lands in the middle of that range.

enum P {
    static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a
        )
    }

    static let accent = rgb(0x3FA9FF)
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

/// The current is drawn one character at a time, so each mark needs to land with
/// its *ink* on the line — not its line box, which is mostly air above a tilde.
/// This nudge is that difference, as a fraction of the font size, and it was set
/// by looking at a render rather than by reading a font metric.
let inkNudge: CGFloat = 0.30

func drawMark(_ ch: String, size: CGFloat, colour: NSColor, centre: CGPoint) -> CGFloat {
    let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    let s = NSAttributedString(string: ch, attributes: [.font: font, .foregroundColor: colour])
    let box = s.size()
    s.draw(at: CGPoint(x: centre.x - box.width / 2, y: centre.y - box.height / 2 + size * inkNudge))
    return box.width
}

// MARK: - The picture

func drawBackground(into ctx: CGContext) {
    let W = L.canvas.width, H = L.canvas.height

    // Nothing fills the canvas. It stays transparent and Finder's own
    // background shows through, which is the whole design — see the top of the
    // file. Everything below draws the one thing that is in the picture.

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

    // ---------------------------------------------------------- the current
    //
    // A run of wave marks flowing out of the app and into the folder, ending in
    // an arrowhead. It is the app's own language for "this is happening" — the
    // icon is four of these stacked — doing the job the usual big grey arrow
    // does, and it is now the only thing in the window that isn't Finder's.
    //
    // It starts and ends against the icons rather than at fixed x's, so moving
    // either icon moves the arrow with it. The gap at the head is bigger than
    // the one at the tail to leave the arrowhead somewhere to sit.
    let streamStart = L.app.x + L.iconSize / 2 + 16
    let streamEnd = L.drop.x - L.iconSize / 2 - 22

    var cx = streamStart
    var index = 0
    while cx < streamEnd {
        let t = (cx - streamStart) / (streamEnd - streamStart)

        // A slow rise and fall, so the run reads as moving water rather than a
        // dashed line. One full wave across the gap, three points either way.
        let yy = L.waterline + sin(t * .pi * 2.2) * 3.4

        // Brightening as it arrives, but starting well up: the earlier version
        // began at 0.30 alpha, which was right against dark water and is
        // nearly invisible on Finder's near-white background in Light Mode.
        let a = 0.55 + 0.45 * t

        // Every fourth mark is a double, which is the app icon's own rhythm.
        // Deterministic on the index rather than seeded randomness — with only
        // a dozen marks left, random spacing read as a mistake rather than as
        // texture, and this way the picture is identical on every build.
        let w = drawMark(
            index % 4 == 2 ? "≈" : "~", size: 19,
            colour: P.accent.withAlphaComponent(a),
            centre: CGPoint(x: cx, y: yy)
        )
        cx += w * 1.02
        index += 1
    }

    // It arrives as an arrowhead, at full strength, because this is the part
    // that is actually an instruction.
    _ = drawMark(">", size: 23, colour: P.accent, centre: CGPoint(x: streamEnd + 6, y: L.waterline))
}

// MARK: - Rendering

func render(scale: CGFloat) -> NSBitmapImageRep {
    let px = (w: Int(L.canvas.width * scale), h: Int(L.canvas.height * scale))
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px.w, pixelsHigh: px.h,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    // Points, not pixels, and reported to AppKit as such — so the size that
    // comes back out of the file is the size the geometry in `L` assumes.
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
    // two-page image here doesn't get you a sharp window, it gets you the
    // top-left quarter of the picture at four times the size.
    //
    // **PNG, not TIFF, and the reason is the download.** TIFF stores this
    // uncompressed, so the old seascape cost 1.1 MB and this arrow on
    // transparency would cost the same — a megabyte of identical empty pixels,
    // inside a file people download. PNG collapses it to a few KB. Finder
    // reads either, and neither format is what the alias record cares about.
    let art = render(scale: 1)
    let out = dir.appendingPathComponent("background.png")
    try art.representation(using: .png, properties: [:])!.write(to: out)

    // Cheap proof the picture comes back at the size the geometry assumes, so
    // a canvas change that AppKit quietly rounds can't slide the whole window.
    guard let check = NSImage(contentsOf: out), check.size == L.canvas
    else { throw Err("the picture came back \(NSImage(contentsOf: out)?.size.debugDescription ?? "unreadable"), not \(L.canvas)") }

    let kb = (try? Data(contentsOf: out).count).map { $0 / 1024 } ?? 0
    print("  background \(Int(L.canvas.width))×\(Int(L.canvas.height)) @1x, \(kb) KB → \(out.path)")
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
    let background = vol.appendingPathComponent(".background/background.png")
    guard FileManager.default.fileExists(atPath: background.path) else {
        throw Err("no .background/background.png on \(volume) — run the `art` step first")
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
