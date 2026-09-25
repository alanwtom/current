import XCTest
@testable import CurrentCore
@testable import CurrentSim

final class SimulationEngineTests: XCTestCase {

    /// Driven by explicit `step()` calls rather than by sleeping.
    ///
    /// This used to start a detached task watching the event stream, sleep
    /// 330 ms of wall clock, and assert that metadata had turned up. That is a
    /// race with the background ticker and the scheduler, and it lost on CI —
    /// a docs-only commit failed here on code that had passed twice already.
    /// A test that fails for reasons unrelated to its subject is worse than no
    /// test: it trains you to re-run the job instead of reading it, and the one
    /// time it means something you'll shrug and hit retry.
    ///
    /// `step()` advances the simulation by exactly one tick, so the timing is
    /// arithmetic instead of a gamble.
    func testMagnetResolvesThenDownloads() async throws {
        let engine = SimulationEngine(
            tickInterval: 0.05,
            baseSpeed: 50_000_000,
            resolveDelay: 0.1
        )
        let stream = await engine.events

        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:abcdef&dn=Test%20Torrent",
            saveDirectory: FileManager.default.temporaryDirectory
        )

        // A 0.1 s resolve delay at 0.05 s per tick needs two ticks; a few more
        // so the torrent is properly downloading by the end.
        for _ in 0..<5 { await engine.step() }

        // Events are buffered, so they are all waiting by now. Bounded so a
        // missing event fails the test rather than hanging the suite.
        var metadata: TorrentMetadata?
        var inspected = 0
        for await event in stream {
            if case .metadataReceived(_, let received) = event {
                metadata = received
                break
            }
            inspected += 1
            if inspected > 30 { break }
        }
        XCTAssertNotNil(metadata, "the magnet never reported its metadata")
        XCTAssertEqual(metadata?.id, id)
    }

    /// The simulator has to hold a magnet the way libtorrent does, or every
    /// screenshot and demo shows a flow the real app doesn't have: resolved,
    /// then stopped, then downloading only once something resumes it.
    func testAHeldMagnetStopsOnceResolvedUntilResumed() async throws {
        let engine = SimulationEngine(tickInterval: 0.05, baseSpeed: 50_000_000, resolveDelay: 0.1)
        let stream = await engine.events
        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:held&dn=Held", saveDirectory: FileManager.default.temporaryDirectory, held: true
        )
        for _ in 0..<5 { await engine.step() }
        await engine.resume(id)
        await engine.step()

        var states: [TorrentState] = []
        var inspected = 0
        for await event in stream {
            if case .snapshots(let batch) = event, let row = batch.first(where: { $0.id == id }) {
                states.append(row.state)
                if states.count == 6 { break }
            }
            inspected += 1
            if inspected > 40 { break }
        }
        XCTAssertEqual(states.first, .resolving)
        XCTAssertEqual(states.dropLast().last, .paused(.user), "resolved and held, it must be stopped")
        XCTAssertEqual(states.last, .downloading, "resume releases it")
        XCTAssertFalse(states.contains(.downloading) && states.firstIndex(of: .downloading)! < states.count - 1,
                       "it must not download before it is resumed")
    }

}

final class DropParserTests: XCTestCase {

    func testExtractsMagnetsFromText() {
        let text = """
        Check these out:
        magnet:?xt=urn:btih:aaa111&dn=One
        and also magnet:?xt=urn:btih:bbb222&dn=Two
        """
        let magnets = DropParser.magnets(in: text)
        XCTAssertEqual(magnets.count, 2)
        XCTAssertTrue(magnets[0].hasPrefix("magnet:?xt=urn:btih:aaa111"))
    }

    func testParsesMixedPasteboardContent() {
        let parsed = DropParser.parse(pasteboard: ["magnet:?xt=urn:btih:xyz"])
        XCTAssertEqual(parsed, [.magnet("magnet:?xt=urn:btih:xyz")])
    }

    // MARK: - URLs handed over by the system
    //
    // This is the path a magnet link clicked in a browser takes, and it was
    // broken in both directions: with the app closed the URL was dropped
    // entirely, and with the app open it also opened a second, empty window.
    // The delivery is AppKit's problem (see `AppDelegate`); what a delivered
    // URL *means* is this, and it's worth pinning.

    func testRecognisesAMagnetURL() {
        let url = URL(string: "magnet:?xt=urn:btih:abc123&dn=Something")!
        XCTAssertEqual(DropParser.parse(url: url), .magnet(url.absoluteString))
    }

    /// URL schemes are case-insensitive, and `MAGNET:` links exist in the wild.
    func testRecognisesAMagnetURLWhateverTheSchemesCase() {
        let upper = URL(string: "MAGNET:?xt=urn:btih:abc123")!
        XCTAssertEqual(DropParser.parse(url: upper), .magnet(upper.absoluteString))

        let mixed = URL(string: "Magnet:?xt=urn:btih:abc123")!
        XCTAssertEqual(DropParser.parse(url: mixed), .magnet(mixed.absoluteString))
    }

    func testRecognisesATorrentFileURL() {
        let url = URL(fileURLWithPath: "/tmp/ubuntu.torrent")
        XCTAssertEqual(DropParser.parse(url: url), .torrentFile(url))

        let shouty = URL(fileURLWithPath: "/tmp/ubuntu.TORRENT")
        XCTAssertEqual(DropParser.parse(url: shouty), .torrentFile(shouty))
    }

    /// Classification, not validation: whether a magnet is *usable* is the
    /// engine's answer to give, and it reports it properly.
    func testAMalformedMagnetIsStillAMagnet() {
        let url = URL(string: "magnet:?dn=NoHashHere")!
        XCTAssertEqual(DropParser.parse(url: url), .magnet(url.absoluteString))
    }

    func testIgnoresAnythingElse() {
        XCTAssertNil(DropParser.parse(url: URL(string: "https://example.com/file.torrent")!))
        XCTAssertNil(DropParser.parse(url: URL(fileURLWithPath: "/tmp/notes.txt")))
        XCTAssertNil(DropParser.parse(url: URL(fileURLWithPath: "/tmp/torrent")))
        XCTAssertNil(DropParser.parse(url: URL(string: "ftp://example.com/x")!))
    }

    func testTorrentFilesOnlyAcceptedByExtension() {
        let torrentURL = URL(fileURLWithPath: "/tmp/thing.torrent")
        let otherURL = URL(fileURLWithPath: "/tmp/other.txt")
        let parsed = DropParser.parse(fileURLs: [torrentURL, otherURL])
        XCTAssertEqual(parsed, [.torrentFile(torrentURL)])
    }

    func testNameHintFromMagnet() {
        XCTAssertEqual(DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=My%20Movie"), "My Movie")
        XCTAssertNil(DropParser.nameHint(fromMagnet: "magnet:?xt=x"))
    }

    /// Real magnets encode spaces as `+`, not `%20`, and the library showed the
    /// plus signs: `Some.Release+Name+Here`.
    func testNameHintDecodesPlusAsSpace() {
        XCTAssertEqual(
            DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=Big+Buck+Bunny+2008"),
            "Big Buck Bunny 2008"
        )
        // Mixed encodings in one name, which is also common.
        XCTAssertEqual(
            DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=Sintel+%282010%29&tr=udp://x"),
            "Sintel (2010)"
        )
    }

    /// A `dn` that isn't valid percent-encoding must still produce a name
    /// rather than nothing — `removingPercentEncoding` returns nil for a stray
    /// `%`, and the library then fell back to showing the info hash.
    func testNameHintSurvivesBadEncoding() {
        XCTAssertEqual(DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=100%+Complete"), "100% Complete")
    }
}

// MARK: - Names from untrusted magnets
//
// A magnet link is something any web page can hand the app, so its `dn=` is
// attacker-controlled text that goes straight into a row and into the library
// database. These pin the two things that has to survive.

extension DropParserTests {

    /// A right-to-left override reverses everything after it, so a name can be
    /// made to display as something it is not — the trick that has been used on
    /// filenames for years. It should never reach a view.
    func testNameHintStripsDirectionOverridesAndControlCharacters() {
        let spoofed = "magnet:?xt=x&dn=" + "invoice\u{202E}fdp.exe".addingPercentEncoding(
            withAllowedCharacters: .alphanumerics
        )!
        let name = DropParser.nameHint(fromMagnet: spoofed)
        XCTAssertNotNil(name)
        XCTAssertFalse(name!.unicodeScalars.contains { $0 == "\u{202E}" },
                       "a bidi override survived into the display name")

        XCTAssertEqual(DropParser.sanitisedName("two\nlines\there"), "twolineshere")
        XCTAssertNil(DropParser.sanitisedName("\u{202E}\u{200F}"),
                     "a name that is nothing but overrides should be treated as no name")
    }

    /// Nothing in the format bounds `dn=`, so the app has to.
    func testNameHintIsLengthBounded() {
        let huge = String(repeating: "A", count: 50_000)
        let name = DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=" + huge)
        XCTAssertEqual(name?.count, DropParser.maximumNameLength)
    }

    /// A display name is never a path. The name reached the filesystem once,
    /// and a `/` in it was part of what made a delete aim at the wrong place.
    func testSanitisedNameStripsSeparatorsAndKeepsTheRest() {
        XCTAssertEqual(DropParser.sanitisedName("a/b"), "ab")
        XCTAssertEqual(DropParser.sanitisedName("Season 1/Episode 1"), "Season 1Episode 1")
        // Nothing left means nil, so the caller falls back to the info hash
        // rather than showing an empty row.
        XCTAssertNil(DropParser.sanitisedName("/"))
        XCTAssertNil(DropParser.sanitisedName("///"))
    }

    /// The name comes from the `dn` key and no other. Matching the text
    /// "dn=" anywhere let `xdn=` stand in for it.
    func testNameHintReadsOnlyTheDnKey() {
        XCTAssertEqual(DropParser.nameHint(fromMagnet: "magnet:?xt=x&xdn=Spoof&dn=Real"), "Real")
        XCTAssertNil(DropParser.nameHint(fromMagnet: "magnet:?xt=x&xdn=Spoof"))
        XCTAssertNil(DropParser.nameHint(fromMagnet: "magnet:?xt=x&dn=&tr=udp://t"))
        XCTAssertEqual(DropParser.nameHint(fromMagnet: "magnet:?DN=Upper&xt=x"), "Upper")
    }
}
