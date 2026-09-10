import XCTest
import CryptoKit
@testable import CurrentCore
@testable import CurrentEngine
// For `NetworkMonitor`: the binding tests below deliberately find an interface
// through the same code the app uses, so a fault in that enumeration fails here
// too rather than being papered over by a hand-written address.
@testable import CurrentApp

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
        // The session opens no listen sockets until it is configured — see
        // `lt_session_create`, which fails closed so that a VPN-confined user
        // never gets a moment of announcing from their real address. The app
        // pushes its configuration during init; a test has to do the same or it
        // has no networking at all.
        await engine.apply(EngineConfiguration())
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
        // The session opens no listen sockets until it is configured — see
        // `lt_session_create`, which fails closed so that a VPN-confined user
        // never gets a moment of announcing from their real address. The app
        // pushes its configuration during init; a test has to do the same or it
        // has no networking at all.
        await engine.apply(EngineConfiguration())
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

    // MARK: - Confining transfers to one connection

    /// Gathers the engine's listen reports so a binding can be checked against
    /// what actually happened.
    ///
    /// Two things here are load-bearing, and both were learned the hard way:
    ///
    /// - The waiting is done with a **sleep, not by reading the stream**. A
    ///   session that is listening nowhere emits nothing at all, so a
    ///   `for await` loop that checks its deadline on each event waits forever
    ///   in exactly the cases these tests exist to cover.
    /// - The collector is **reset after the binding is applied**. A fresh
    ///   session binds to everything before the test reconfigures it, and
    ///   libtorrent does not always report the resulting teardown — so the
    ///   pre-binding successes have to be discarded rather than contradicted.
    ///
    /// `discardingInitialReports` exists because libtorrent only re-opens its
    /// listen sockets when the setting genuinely changes — applying a value it
    /// already holds emits nothing. A test that reconfigures to the *same*
    /// binding therefore has to keep the creation-time reports rather than
    /// wait for replacements that will never come.
    /// A port nothing else on the machine is likely to want.
    ///
    /// Not 6881. Binding switches the OS port fallback *off* on purpose — a
    /// bind that fails has to fail rather than quietly land somewhere else — so
    /// a test on the default port fails the moment a real copy of Current (or
    /// any other torrent client) is running on the same Mac. That is correct
    /// behaviour and a useless test, and it cost a confusing hour.
    private static let testPort = 51999

    private func listenAddresses(
        of engine: LibtorrentEngine,
        events: AsyncStream<EngineEvent>,
        binding: BindingOutcome,
        seconds: TimeInterval = 6,
        discardingInitialReports: Bool = true
    ) async -> (addresses: Set<String>, failures: [String]) {
        actor Collector {
            private var state = ListenState.unknown
            private var failures: [String] = []

            func apply(_ report: ListenReport) {
                state.apply(report)
                if !report.succeeded { failures.append(report.message) }
            }
            func reset() {
                state = .unknown
                failures = []
            }
            func result() -> (Set<String>, [String]) { (state.addresses, failures) }
        }

        let collector = Collector()
        let reader = Task {
            for await event in events {
                if case .listenChanged(let report) = event {
                    await collector.apply(report)
                }
            }
        }
        defer { reader.cancel() }

        // Let the session's own creation-time bind finish being reported first,
        // then throw those away — the order matters, because resetting *after*
        // the new bind would discard the very reports being measured.
        try? await Task.sleep(for: .seconds(3))
        await engine.apply(
            EngineConfiguration(listenPort: Self.testPort, binding: binding)
        )
        if discardingInitialReports { await collector.reset() }

        try? await Task.sleep(for: .seconds(seconds))
        let (addresses, failures) = await collector.result()
        return (addresses, failures)
    }

    /// The engine must report where it *really* bound, not where it was asked
    /// to. Without this the app's binding indicator is unfalsifiable — which is
    /// how every comparable client has ended up showing "bound" while traffic
    /// went out the real connection.
    func testTheEngineReportsTheAddressItActuallyListensOn() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let engine = LibtorrentEngine()
        let events = await engine.events
        let result = await listenAddresses(
            of: engine, events: events, binding: .unrestricted,
            discardingInitialReports: false
        )

        XCTAssertFalse(
            result.addresses.isEmpty,
            "the engine opened no listen sockets at all, so nothing downstream can confirm a binding"
        )
    }

    /// An unconfined session listens on more than one interface, which is the
    /// fault this feature fixes rather than a nicety.
    ///
    /// Listening on `0.0.0.0` makes libtorrent open a socket per interface and
    /// announce from each, so a machine with a VPN up tells the tracker both
    /// the tunnel address and the real one. Skipped on a machine with only one
    /// usable interface, where there is nothing to demonstrate.
    func testAnUnconfinedSessionListensOnEveryInterface() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let usable = await MainActor.run { NetworkMonitor().selectableInterfaces }
        try XCTSkipUnless(usable.count > 1, "only one usable interface on this Mac")

        let engine = LibtorrentEngine()
        let events = await engine.events
        let result = await listenAddresses(
            of: engine, events: events, binding: .unrestricted,
            discardingInitialReports: false
        )

        print("  unconfined, listening on: \(result.addresses.sorted())")
        XCTAssertGreaterThan(
            result.addresses.count, 1,
            "expected an unconfined session to listen on several addresses"
        )
    }

    /// A device that cannot exist must produce no listen sockets.
    ///
    /// This is the shape of a dropped VPN, and the assertion is the one that
    /// matters: **not** that it fails over to the real connection. An interface
    /// name is capped at 15 characters by the OS and cannot contain a hyphen,
    /// so nothing on any Mac matches this.
    func testBindingToADeviceThatCannotExistListensNowhere() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let engine = LibtorrentEngine()
        let events = await engine.events
        let result = await listenAddresses(
            of: engine, events: events,
            binding: .bound(device: "current-nodev", carriesIPv6: false)
        )

        XCTAssertTrue(
            result.addresses.isEmpty,
            "bound to a nonexistent device and still listening on \(result.addresses) — the binding is not being applied"
        )
    }

    /// Losing the connection has to mean nothing is listening, and it must not
    /// be treated as "no binding requested".
    func testALostConnectionListensNowhere() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let engine = LibtorrentEngine()
        let events = await engine.events
        let result = await listenAddresses(
            of: engine, events: events,
            binding: .unavailable(reason: "no VPN")
        )

        XCTAssertTrue(
            result.addresses.isEmpty,
            "a blocked network is still listening on \(result.addresses)"
        )
    }

    /// **The test that proves the feature.** Bound to a device that exists,
    /// every listen socket must sit on one of that device's own addresses and
    /// on no others.
    ///
    /// Uses a real interface on the machine running the tests rather than
    /// loopback: libtorrent declines to open listen sockets on `lo0` at all, so
    /// a loopback test proves only that nothing happened. The production
    /// enumeration path is used to find one, so a bug in that shows up here too.
    func testBindingToARealDeviceListensOnlyOnThatDevice() async throws {
        try XCTSkipUnless(isEnabled, "set CURRENT_REAL_NETWORK=1 to run")

        let candidates = await MainActor.run {
            NetworkMonitor().selectableInterfaces.filter {
                $0.kind == .ordinary && $0.hasIPv4
            }
        }
        guard let target = candidates.first else {
            throw XCTSkip("no ordinary interface with an address to bind to")
        }

        let engine = LibtorrentEngine()
        let events = await engine.events
        let result = await listenAddresses(
            of: engine, events: events,
            binding: .bound(device: target.name, carriesIPv6: target.hasIPv6)
        )

        print("  bound to \(target.name), listening on: \(result.addresses.sorted())")
        XCTAssertFalse(
            result.addresses.isEmpty,
            "nothing bound to \(target.name) at all: \(result.failures)"
        )

        // Checked through the same call the settings screen uses, so this
        // proves the *indicator* as well as the binding. An earlier version
        // compared addresses by hand here and passed while the real check was
        // reporting a leak on every bind.
        let state = ListenState(addresses: result.addresses)
        XCTAssertEqual(
            state.confirms(device: target.name, addresses: target.addresses), true,
            """
            bound to \(target.name) and listening on \(result.addresses.sorted()), \
            but that device only has \(target.addresses.sorted()) — \
            either traffic is leaving by another interface, or the check is wrong
            """
        )
    }
}
