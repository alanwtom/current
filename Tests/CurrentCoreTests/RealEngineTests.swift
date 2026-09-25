import XCTest
import CryptoKit
@testable import CurrentCore
@testable import CurrentEngine

/// The real libtorrent engine, offline.
///
/// Everything else in the suite runs against `SimulationEngine`, which is why
/// the libtorrent path could lose every torrent on relaunch without a single
/// test noticing: the simulator's resume data is its own JSON, so the restore
/// that fed libtorrent's resume blob to its .torrent parser was never run by
/// anything but a person. These tests build real torrents from local files and
/// drive the real engine with them — no internet, no tracker, no DHT. Where two
/// sessions have to meet, they meet over loopback.
///
/// They cost a few seconds, because libtorrent's stats tick is one second and a
/// recheck is real hashing. That is the price of testing the thing itself.
@MainActor
final class RealEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// A small file, a v1 .torrent describing it, and its info-hash.
    struct Fixture {
        let directory: URL
        let name: String
        let content: Data
        let torrent: Data
        let infoHash: String
    }

    /// 64 KiB and a bit, in 16 KiB pieces — so the last piece is short, which
    /// is the case piece arithmetic gets wrong.
    private func makeFixture(name: String = "payload.bin", writeContent: Bool = true) throws -> Fixture {
        let directory = try makeScratchDirectory(self, "engine")
        var generator = SystemRandomNumberGenerator()
        let content = Data((0..<(64 * 1024 + 100)).map { _ in UInt8.random(in: 0...255, using: &generator) })
        if writeContent {
            try content.write(to: directory.appendingPathComponent(name))
        }
        let pieceLength = 16 * 1024
        var pieces = Data()
        var offset = 0
        while offset < content.count {
            let chunk = content[offset..<min(offset + pieceLength, content.count)]
            pieces.append(contentsOf: Insecure.SHA1.hash(data: chunk))
            offset += pieceLength
        }
        let info: Bencode = .dict([
            "length": .int(content.count),
            "name": .bytes(Data(name.utf8)),
            "piece length": .int(pieceLength),
            "pieces": .bytes(pieces),
        ])
        let infoBytes = info.encoded()
        let hash = Insecure.SHA1.hash(data: infoBytes).map { String(format: "%02x", $0) }.joined()
        let torrent = Bencode.dict(["info": info]).encoded()
        return Fixture(directory: directory, name: name, content: content, torrent: torrent, infoHash: hash)
    }

    /// An engine with no saved DHT state and no network until it is told.
    private func makeEngine(binding: BindingOutcome = .unavailable(reason: "test")) async -> LibtorrentEngine {
        let engine = LibtorrentEngine(statePath: "")
        await engine.apply(Self.offline(binding: binding))
        addTeardownBlock { await engine.shutdown() }
        return engine
    }

    /// Discovery off in every form, so the only way two sessions meet is the
    /// one the test arranges.
    private static func offline(binding: BindingOutcome, port: Int = 0) -> EngineConfiguration {
        EngineConfiguration(
            listenPort: port,
            isDHTEnabled: false,
            isLocalDiscoveryEnabled: false,
            isPortMappingEnabled: false,
            binding: binding
        )
    }

    // MARK: - A torrent whose data is already there

    func testATorrentWhoseDataIsOnDiskChecksToSeeding() async throws {
        let fixture = try makeFixture()
        let engine = await makeEngine()
        let watcher = EngineWatcher(engine)

        let id = try await engine.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory)
        XCTAssertEqual(id.raw, fixture.infoHash, "the id is the info-hash, not something the shim made up")

        let seeding = await watcher.waitFor(id) { $0.progress >= 1 && $0.state == .seeding }
        XCTAssertNotNil(seeding, "a complete file on disk must verify and seed")
        // The ABI canary, as a test: these read back garbage when the shim's
        // compile definitions disagree with libtorrent's.
        XCTAssertEqual(seeding?.totalBytes, Int64(fixture.content.count))
        XCTAssertEqual(seeding?.hasMetadata, true)

        let metadata = watcher.metadata(for: id)
        XCTAssertEqual(metadata?.displayName, fixture.name)
        XCTAssertEqual(metadata?.files.map(\.size), [Int64(fixture.content.count)])
    }

    func testOneCorruptByteIsCaught() async throws {
        let fixture = try makeFixture()
        var damaged = fixture.content
        damaged[20_000] ^= 0xFF
        try damaged.write(to: fixture.directory.appendingPathComponent(fixture.name))

        let engine = await makeEngine()
        let watcher = EngineWatcher(engine)
        let id = try await engine.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory)

        // Checked, and short by exactly the damaged piece: a torrent that
        // reported complete here would be seeding corrupt data.
        let checked = await watcher.waitFor(id) { $0.hasMetadata && $0.state != .checking && $0.progress > 0 }
        XCTAssertNotNil(checked)
        XCTAssertLessThan(checked?.progress ?? 1, 1)
        XCTAssertNotEqual(checked?.state, .seeding)
    }

    // MARK: - Relaunch

    /// **The regression.** Resume data used to be fed to libtorrent's .torrent
    /// parser, which rejects it — silently, through a `try?` — so no torrent
    /// the engine was running ever came back after a relaunch.
    func testResumeDataRestoresTheTorrentInAFreshSession() async throws {
        let fixture = try makeFixture()

        let first = await makeEngine()
        let firstWatcher = EngineWatcher(first)
        let id = try await first.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory)
        _ = await firstWatcher.waitFor(id) { $0.state == .seeding }
        let blob = await first.resumeData(for: id)
        let resume = try XCTUnwrap(blob, "a seeding torrent must produce resume data")
        await first.shutdown()

        let second = await makeEngine()
        let watcher = EngineWatcher(second)
        let restored = try await second.add(.resumeData(resume), saveDirectory: fixture.directory)

        XCTAssertEqual(restored, id)
        let seeding = await watcher.waitFor(restored) { $0.state == .seeding && $0.progress >= 1 }
        XCTAssertNotNil(seeding, "the restored torrent must come back complete")
        // The blob carries the info dict now, so a restore knows its files
        // without a peer to ask.
        let metadata = watcher.metadata(for: restored)
        XCTAssertEqual(metadata?.displayName, fixture.name)
        // libtorrent says "finished" when a restored seed's check ends, and the
        // app turned that into "Download complete" for every seed in the
        // library at every launch. Nothing downloaded, so nothing finished.
        XCTAssertEqual(watcher.completed, [], "a restored seed announced itself as a new download")
    }

    func testGarbageResumeDataIsRefusedNotFatal() async throws {
        let engine = await makeEngine()
        let directory = try makeScratchDirectory(self)
        do {
            _ = try await engine.add(.resumeData(Data("d4:junki1ee".utf8)), saveDirectory: directory)
            XCTFail("resume data with no info-hash must not produce a torrent")
        } catch is EngineFailure {
        }
    }

    /// libtorrent answers a torrent it already has with *that* torrent rather
    /// than an error. The app relies on knowing which — `alreadyInLibrary`
    /// catches the same id coming back, because treating it as new put the
    /// confirm card over a download that was already running.
    func testAddingATorrentTwiceGivesBackTheSameOne() async throws {
        let fixture = try makeFixture()
        let engine = await makeEngine()
        let first = try await engine.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory)
        let second = try await engine.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory, held: true)
        XCTAssertEqual(first, second)
        let magnet = try await engine.addMagnet("magnet:?xt=urn:btih:\(fixture.infoHash)", saveDirectory: fixture.directory, held: true)
        XCTAssertEqual(first, magnet)
    }

    // MARK: - Held

    /// A held torrent is one nobody has said yes to. It must not write a byte.
    func testAHeldTorrentFileWritesNothingUntilResumed() async throws {
        let fixture = try makeFixture(writeContent: false)
        let engine = await makeEngine(binding: .unrestricted)
        let watcher = EngineWatcher(engine)

        let id = try await engine.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory, held: true)
        let held = await watcher.waitFor(id) { _ in true }
        XCTAssertEqual(held?.state, .paused(.user))

        // A couple more ticks, and still nothing on disk.
        _ = await watcher.waitFor(id, timeout: .seconds(2.5)) { _ in false }
        XCTAssertEqual(watcher.latest[id]?.state, .paused(.user))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [])

        await engine.resume(id)
        let released = await watcher.waitFor(id) { $0.state != .paused(.user) }
        XCTAssertNotNil(released, "resume must release a held torrent")
    }

    // MARK: - Two sessions over loopback

    /// The whole path, for real: a held magnet on one session fetches its
    /// metadata from a seeder on another, stops without downloading, and only
    /// after `resume` transfers the file — byte for byte.
    func testAHeldMagnetGetsItsDetailsThenOnlyDownloadsWhenReleased() async throws {
        let fixture = try makeFixture()
        let (seeder, port) = try await makeSeeder(fixture)

        let leecherDirectory = try makeScratchDirectory(self, "leech")
        let leecher = await makeEngine(binding: .bound(device: "lo0", carriesIPv6: true))
        let watcher = EngineWatcher(leecher)
        let magnet = "magnet:?xt=urn:btih:\(fixture.infoHash)&dn=\(fixture.name)"

        let id = try await leecher.addMagnet(magnet, saveDirectory: leecherDirectory, held: true)
        await leecher.connectPeer(id, host: "127.0.0.1", port: port)

        let metadata = await watcher.waitForMetadata(id)
        XCTAssertEqual(metadata?.displayName, fixture.name, "held must still fetch the details")
        let parked = await watcher.waitFor(id) { $0.hasMetadata && $0.state == .paused(.user) }
        XCTAssertNotNil(parked, "a held magnet stops once it knows what it is")
        XCTAssertEqual(parked?.downloadedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leecherDirectory.appendingPathComponent(fixture.name).path))

        await leecher.resume(id)
        await leecher.connectPeer(id, host: "127.0.0.1", port: port)
        let done = await watcher.waitFor(id, timeout: .seconds(20)) { $0.progress >= 1 }
        XCTAssertNotNil(done, "released, it must download")
        let written = try Data(contentsOf: leecherDirectory.appendingPathComponent(fixture.name))
        XCTAssertEqual(written, fixture.content)
        let announced = await eventually { watcher.completed == [id] }
        XCTAssertTrue(announced, "a torrent that really downloaded must still say it finished")
        _ = seeder
    }

    /// With the confined connection gone, nothing gets out — not even to a
    /// peer the torrent was explicitly pointed at.
    func testAnUnavailableBindingReachesNoPeer() async throws {
        let fixture = try makeFixture()
        let (seeder, port) = try await makeSeeder(fixture)

        let leecher = await makeEngine(binding: .unavailable(reason: "VPN down"))
        let watcher = EngineWatcher(leecher)
        let directory = try makeScratchDirectory(self, "blocked")
        let id = try await leecher.addMagnet(
            "magnet:?xt=urn:btih:\(fixture.infoHash)", saveDirectory: directory
        )
        await leecher.connectPeer(id, host: "127.0.0.1", port: port)

        // The control for this wait is the test above: the same seeder hands
        // over metadata in well under a second when the leecher is allowed out.
        let leaked = await watcher.waitForMetadata(id, timeout: .seconds(4))
        XCTAssertNil(leaked, "a blocked session must not reach any peer")
        _ = seeder
    }

    /// A magnet's peer list is text a web page wrote. Local addresses in it are
    /// dropped before libtorrent sees them — otherwise a link is a way to make
    /// this Mac connect to machines on its own network.
    func testLocalPeersNamedInAMagnetAreIgnored() async throws {
        let fixture = try makeFixture()
        let (seeder, port) = try await makeSeeder(fixture)

        let leecher = await makeEngine(binding: .bound(device: "lo0", carriesIPv6: true))
        let watcher = EngineWatcher(leecher)
        let directory = try makeScratchDirectory(self, "lan")
        let id = try await leecher.addMagnet(
            "magnet:?xt=urn:btih:\(fixture.infoHash)&x.pe=127.0.0.1:\(port)",
            saveDirectory: directory
        )

        let reached = await watcher.waitForMetadata(id, timeout: .seconds(4))
        XCTAssertNil(reached, "x.pe=127.0.0.1 must not be dialled")
        _ = seeder
    }

    // MARK: - Hostile .torrent files

    func testMalformedTorrentFilesAreRefusedNotFatal() async throws {
        let engine = await makeEngine()
        let directory = try makeScratchDirectory(self)
        let fixture = try makeFixture()

        let deep = Data(String(repeating: "l", count: 10_000).utf8) + Data(String(repeating: "e", count: 10_000).utf8)
        let cases: [(String, Data)] = [
            ("truncated", fixture.torrent.prefix(fixture.torrent.count / 2)),
            ("empty", Data()),
            ("not bencode", Data("<html>404</html>".utf8)),
            ("nested ten thousand deep", deep),
            ("pieces not a multiple of twenty", Bencode.dict(["info": .dict([
                "length": .int(10), "name": .bytes(Data("x".utf8)),
                "piece length": .int(16384), "pieces": .bytes(Data(repeating: 1, count: 19)),
            ])]).encoded()),
            ("length the pieces don't cover", Bencode.dict(["info": .dict([
                "length": .int(1 << 40), "name": .bytes(Data("x".utf8)),
                "piece length": .int(16384), "pieces": .bytes(Data(repeating: 1, count: 20)),
            ])]).encoded()),
        ]
        for (label, data) in cases {
            do {
                _ = try await engine.add(.torrentFile(data), saveDirectory: directory)
                XCTFail("\(label): must be refused")
            } catch is EngineFailure {
            }
        }
    }

    /// A torrent's name and paths are the torrent author's to choose. Whatever
    /// they chose, what reaches the app must be one safe path component.
    func testTraversalInATorrentsNamesNeverReachesTheApp() async throws {
        let engine = await makeEngine()
        let watcher = EngineWatcher(engine)
        let directory = try makeScratchDirectory(self)

        let hostileNames = ["../../escape", "a/b", "..", "evil\u{202E}gpj.app"]
        for (index, hostile) in hostileNames.enumerated() {
            let info: Bencode = .dict([
                "name": .bytes(Data(hostile.utf8)),
                "piece length": .int(16384),
                "pieces": .bytes(Data(repeating: UInt8(index), count: 20)),
                "files": .list([
                    .dict(["length": .int(10), "path": .list([.bytes(Data("..".utf8)), .bytes(Data("..".utf8)), .bytes(Data("evil".utf8))])]),
                    .dict(["length": .int(10), "path": .list([.bytes(Data("ok.txt".utf8))])]),
                ]),
            ])
            let id = try await engine.add(.torrentFile(Bencode.dict(["info": info]).encoded()), saveDirectory: directory)
            let arrived = await watcher.waitForMetadata(id)
            let metadata = try XCTUnwrap(arrived, hostile)

            let name = metadata.displayName
            XCTAssertFalse(name.contains("/"), "\(hostile) -> \(name)")
            XCTAssertNotEqual(name, "..")
            XCTAssertFalse(name.unicodeScalars.contains("\u{202E}"), "direction override survived: \(hostile)")
            for file in metadata.files {
                XCTAssertFalse(file.pathComponents.contains(".."), "\(hostile): \(file.pathComponents)")
            }
            XCTAssertTrue(ContentLocation.isSafeComponent(name), "\(hostile) -> \(name)")
            XCTAssertNotNil(ContentLocation.ownedFiles(saveDirectory: directory, files: metadata.files))
        }
    }

    // MARK: - Helpers

    /// A session seeding `fixture` on loopback, and the port it listens on.
    private func makeSeeder(_ fixture: Fixture) async throws -> (LibtorrentEngine, Int) {
        let seeder = LibtorrentEngine(statePath: "")
        addTeardownBlock { await seeder.shutdown() }
        let watcher = EngineWatcher(seeder)
        // A fixed port from the dynamic range, per test run. Binding to lo0
        // turns the OS port fallback off, so a busy port fails loudly rather
        // than landing somewhere the leecher won't look.
        let port = Int.random(in: 49_152...65_000)
        await seeder.apply(Self.offline(binding: .bound(device: "lo0", carriesIPv6: true), port: port))
        let id = try await seeder.add(.torrentFile(fixture.torrent), saveDirectory: fixture.directory)
        let seeding = await watcher.waitFor(id) { $0.state == .seeding }
        XCTAssertNotNil(seeding, "seeder must verify its own copy first")
        let listening = await watcher.waitForListen { $0.succeeded && $0.address == "127.0.0.1" }
        XCTAssertNotNil(listening, "seeder must be listening on loopback")
        return (seeder, listening?.port ?? port)
    }
}

// MARK: - Watching an engine

/// Collects what an engine reports so tests can wait on it.
@MainActor
final class EngineWatcher {
    private(set) var latest: [TorrentID: TorrentSnapshot] = [:]
    private(set) var metadataByID: [TorrentID: TorrentMetadata] = [:]
    private(set) var listens: [ListenReport] = []
    private(set) var completed: [TorrentID] = []
    private var task: Task<Void, Never>?

    init(_ engine: LibtorrentEngine) {
        let stream = engine.events
        task = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .snapshots(let batch):
                    for snapshot in batch { self.latest[snapshot.id] = snapshot }
                case .metadataReceived(let id, let metadata):
                    self.metadataByID[id] = metadata
                case .listenChanged(let report):
                    self.listens.append(report)
                case .completed(let id):
                    self.completed.append(id)
                default:
                    break
                }
            }
        }
    }

    deinit { task?.cancel() }

    func metadata(for id: TorrentID) -> TorrentMetadata? { metadataByID[id] }

    func waitFor(
        _ id: TorrentID, timeout: Duration = .seconds(10),
        _ predicate: (TorrentSnapshot) -> Bool
    ) async -> TorrentSnapshot? {
        let ok = await eventually(timeout: timeout) {
            self.latest[id].map(predicate) ?? false
        }
        return ok ? latest[id] : nil
    }

    func waitForMetadata(_ id: TorrentID, timeout: Duration = .seconds(10)) async -> TorrentMetadata? {
        _ = await eventually(timeout: timeout) { self.metadataByID[id] != nil }
        return metadataByID[id]
    }

    func waitForListen(timeout: Duration = .seconds(5), _ predicate: (ListenReport) -> Bool) async -> ListenReport? {
        _ = await eventually(timeout: timeout) { self.listens.contains(where: predicate) }
        return listens.first(where: predicate)
    }
}

// MARK: - Bencode, just enough to write a .torrent

indirect enum Bencode {
    case int(Int)
    case bytes(Data)
    case list([Bencode])
    case dict([String: Bencode])

    func encoded() -> Data {
        switch self {
        case .int(let value):
            return Data("i\(value)e".utf8)
        case .bytes(let data):
            return Data("\(data.count):".utf8) + data
        case .list(let items):
            return items.reduce(into: Data("l".utf8)) { $0 += $1.encoded() } + Data("e".utf8)
        case .dict(let entries):
            // Keys sorted as raw bytes, which is what makes an info-hash stable.
            let sorted = entries.sorted { Array($0.key.utf8).lexicographicallyPrecedes(Array($1.key.utf8)) }
            var out = Data("d".utf8)
            for (key, value) in sorted {
                out += Bencode.bytes(Data(key.utf8)).encoded() + value.encoded()
            }
            return out + Data("e".utf8)
        }
    }
}
