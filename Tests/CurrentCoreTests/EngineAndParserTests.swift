import XCTest
@testable import CurrentCore
@testable import CurrentSim

final class SimulationEngineTests: XCTestCase {

    func testMagnetResolvesThenDownloads() async throws {
        let engine = SimulationEngine(
            tickInterval: 0.05,
            baseSpeed: 50_000_000,
            resolveDelay: 0.1
        )

        let monitorBox = MetadataBox()
        let monitor = Task.detached { [weak engine] in
            guard let stream = await engine?.events else { return }
            for await event in stream {
                if case .metadataReceived(_, let meta) = event {
                    await MainActor.run { monitorBox.value = meta }
                    break
                }
            }
        }

        let id = try await engine.addMagnet(
            "magnet:?xt=urn:btih:abcdef&dn=Test%20Torrent",
            saveDirectory: FileManager.default.temporaryDirectory
        )

        // Still resolving before the delay elapses.
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = engine

        try await Task.sleep(nanoseconds: 300_000_000)
        monitor.cancel()
        XCTAssertNotNil(monitorBox.value)

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
}


final class MetadataBox: @unchecked Sendable {
    var value: TorrentMetadata?
}
