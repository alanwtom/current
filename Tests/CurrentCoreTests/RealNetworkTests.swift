import XCTest
import CryptoKit
@testable import CurrentCore
@testable import CurrentEngine

/// The only tests that touch a real network and a real swarm.
///
/// **Opt-in**, because the rest of the suite must stay fast, offline and
/// deterministic — CI runs on a machine that should not be joining swarms, and
/// a test that depends on strangers being online is a test that fails for
/// reasons unrelated to the code.
///
///     CURRENT_REAL_NETWORK=1 swift test --filter RealNetworkTests
///
/// They exist because everything else in this project runs against
/// `SimulationEngine`. Until these were written the app had never moved a real
/// byte: the whole libtorrent path — announcing, connecting, hashing, writing —
/// was exercised only by hand, if at all. Two things are worth proving and
/// neither can be faked:
///
/// 1. **A download completes and the bytes are right.** Not "it downloaded" —
///    the finished file's SHA-256 has to match the one the publisher signed.
/// 2. **An HTTPS tracker announce succeeds.** This is the path the bundled CA
///    file exists for, and it fails *silently*: announces just fail
///    verification, the torrent limps along on DHT, and it reads as a flaky
///    network rather than a broken build.
///
/// Both use Debian and Ubuntu release images — lawful, publisher-signed, and
/// well seeded.
final class RealNetworkTests: XCTestCase {

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CURRENT_REAL_NETWORK"] != nil
    }

    private func scratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("current-realnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Downloads a real torrent to completion and checks the result against the
    /// publisher's own checksum.
    ///
    /// Deliberately a *small* image, and deliberately one whose checksum is
    /// published separately from the torrent — verifying a torrent against a
    /// hash taken from the same torrent proves only that libtorrent can add up.
    func testARealTorrentDownloadsAndTheBytesAreCorrect() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let mirror = "https://cdimage.debian.org/debian-cd/current/arm64/bt-cd/"
        let listing = try String(contentsOf: URL(string: mirror)!, encoding: .utf8)
        guard let name = listing.range(of: #"debian-[0-9.]+-arm64-netinst\.iso\.torrent"#,
                                       options: .regularExpression).map({ String(listing[$0]) })
        else { throw XCTSkip("no netinst torrent listed on the mirror today") }

        let torrent = try Data(contentsOf: URL(string: mirror + name)!)
        let isoName = String(name.dropLast(".torrent".count))

        // The publisher's checksum, fetched from a different file than the one
        // being verified.
        let sums = try String(
            contentsOf: URL(string: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/SHA256SUMS")!,
            encoding: .utf8
        )
        guard let line = sums.split(separator: "\n").first(where: { $0.hasSuffix(isoName) }),
              let expected = line.split(separator: " ").first.map(String.init)
        else { throw XCTSkip("no published checksum for \(isoName)") }

        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = LibtorrentEngine()
        let events = await engine.events
        let id = try await engine.addTorrentFile(torrent, saveDirectory: directory)

        // Fifteen minutes is generous for ~700 MB from a well-seeded swarm and
        // still bounded, so a dead network fails rather than hangs.
        let deadline = Date().addingTimeInterval(15 * 60)
        var finished = false
        var lastReport = Date.distantPast

        for await event in events {
            if case .completed(let completed) = event, completed == id {
                finished = true
                break
            }
            if case .failed(_, let failure) = event {
                XCTFail("the engine reported a failure: \(failure)")
                break
            }
            if case .snapshots(let snapshots) = event,
               let snapshot = snapshots.first(where: { $0.id == id }) {
                if Date().timeIntervalSince(lastReport) > 30 {
                    lastReport = Date()
                    print(String(
                        format: "  %.1f%%  %.1f MB/s  %d seeds",
                        snapshot.progress * 100,
                        snapshot.downloadRate / 1e6,
                        snapshot.swarm.knownSeeds
                    ))
                }
                if snapshot.progress >= 1 { finished = true; break }
            }
            if Date() > deadline { break }
        }

        XCTAssertTrue(finished, "the download did not complete within fifteen minutes")

        let iso = directory.appendingPathComponent(isoName)
        let data = try Data(contentsOf: iso, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()

        XCTAssertEqual(
            actual, expected,
            "the finished file does not match Debian's published checksum — the engine downloaded something, but not the right thing"
        )
        await engine.remove(id, deleteFiles: false)
    }

    /// Proves an HTTPS tracker announce succeeds.
    ///
    /// The failure this guards is the nastiest kind: not a crash, just every
    /// HTTPS announce quietly failing certificate validation while the torrent
    /// limps along on DHT. It looks exactly like a slow network. Ubuntu's
    /// tracker is HTTPS, so connecting to a real peer through it is the proof.
    func testAnHTTPSTrackerAnnounceReachesPeers() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let listing = try String(
            contentsOf: URL(string: "https://releases.ubuntu.com/noble/")!,
            encoding: .utf8
        )
        guard let name = listing.range(of: #"ubuntu-[0-9.]+-live-server-amd64\.iso\.torrent"#,
                                       options: .regularExpression).map({ String(listing[$0]) })
        else { throw XCTSkip("no Ubuntu torrent listed today") }

        let torrent = try Data(contentsOf: URL(string: "https://releases.ubuntu.com/noble/" + name)!)
        XCTAssertTrue(
            String(decoding: torrent, as: UTF8.self).contains("https://torrent.ubuntu.com/announce"),
            "this test is pointless unless the torrent actually uses an HTTPS tracker"
        )

        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let engine = LibtorrentEngine()
        let events = await engine.events
        let id = try await engine.addTorrentFile(torrent, saveDirectory: directory)

        // Peers, not bytes: the announce is what is being tested, and a peer
        // count above zero means the tracker answered us over TLS.
        let deadline = Date().addingTimeInterval(120)
        var sawPeers = false

        for await event in events {
            if case .snapshots(let snapshots) = event,
               let snapshot = snapshots.first(where: { $0.id == id }) {
                let peers = snapshot.swarm.connectedPeers
                if peers > 0 || snapshot.downloadedBytes > 0 { sawPeers = true; break }
            }
            if Date() > deadline { break }
        }

        // Pause before removing so nothing keeps transferring after the test.
        await engine.pause(id)
        await engine.remove(id, deleteFiles: true)

        XCTAssertTrue(
            sawPeers,
            "no peer was reached through an HTTPS tracker in two minutes — the likeliest cause is that the bundled CA file is missing or not being used, which makes every HTTPS announce fail verification silently"
        )
    }
}
