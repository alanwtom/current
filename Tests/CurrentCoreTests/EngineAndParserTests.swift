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

        // Pause/resume round trip.
        await engine.pause(id)
        await engine.resume(id)

        // Priorities apply without error.
        await engine.setFilePriorities(id, [.normal, .skip, .normal])

        let resumeData = await engine.resumeData(for: id)
        XCTAssertNotNil(resumeData)
    }

    func testDisplayNameParsing() {
        XCTAssertEqual(
            SimulationEngine.displayName(fromMagnet: "magnet:?xt=urn:btih:abc&dn=Ubuntu%2026.04", index: 1),
            "Ubuntu 26.04"
        )
        XCTAssertEqual(
            SimulationEngine.displayName(fromMagnet: "magnet:?xt=urn:btih:abc", index: 2),
            "Sample torrent 2"
        )
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
