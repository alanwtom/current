import XCTest
import CurrentCore
import CurrentSim

/// Guards the property that makes `-simulate` worth running.
///
/// `AGENTS.md` asks for every UI change to be checked against the simulator,
/// which only means something if the simulator can actually produce the states
/// the UI draws. It could not: swarm figures were derived from the connection
/// count by multiplying it, which floored every simulated torrent above the
/// "healthy" threshold, and the peer-list count was fabricated as
/// `connections + 2`, which is never zero and so kept the "nobody has reported"
/// path unreachable. Between them, three of the four swarm states could not be
/// seen in the one environment meant to exercise them.
///
/// This is the cheap check that would have caught it.
final class SimulationFidelityTests: XCTestCase {

    func testEverySwarmHealthStateIsReachableInTheSimulator() async throws {
        // A resolve delay longer than a tick, so there are ticks where nothing
        // has announced yet — the state a real torrent is in right after you
        // paste a magnet.
        let engine = SimulationEngine(tickInterval: 0.01, resolveDelay: 0.05)
        let stream = await engine.events

        for i in 0..<8 {
            _ = try await engine.addMagnet(
                "magnet:?xt=urn:btih:fidelity\(i)",
                saveDirectory: FileManager.default.temporaryDirectory
            )
        }
        for _ in 0..<12 { await engine.step() }

        var seen = Set<SwarmHealth>()
        var batches = 0
        for await event in stream {
            if case .snapshots(let batch) = event {
                for snapshot in batch { seen.insert(SwarmHealth(swarm: snapshot.swarm)) }
                batches += 1
            }
            if batches >= 12 { break }
        }

        for state in [SwarmHealth.unknown, .rare, .moderate, .healthy] {
            XCTAssertTrue(
                seen.contains(state),
                "\(state.label) cannot occur under -simulate, so no UI that depends on it can be checked there"
            )
        }
    }

    /// The distinction the whole feature rests on, end to end through an engine:
    /// a swarm we have been told about is not the same as one we are connected
    /// to, and the simulator has to keep them apart or it cannot reproduce the
    /// bug this was built to fix.
    func testSwarmSizeIsIndependentOfConnectionCount() async throws {
        let engine = SimulationEngine(tickInterval: 0.01, resolveDelay: 0.0)
        let stream = await engine.events
        for i in 0..<8 {
            _ = try await engine.addMagnet(
                "magnet:?xt=urn:btih:independent\(i)",
                saveDirectory: FileManager.default.temporaryDirectory
            )
        }
        for _ in 0..<4 { await engine.step() }

        var differed = false
        var batches = 0
        for await event in stream {
            if case .snapshots(let batch) = event {
                for snapshot in batch {
                    if let swarmSeeds = snapshot.swarm.swarmSeeds,
                       swarmSeeds != snapshot.swarm.connectedSeeds {
                        differed = true
                    }
                }
                batches += 1
            }
            if batches >= 4 { break }
        }
        XCTAssertTrue(differed, "swarm size never differs from the connection count")
    }

    /// The same problem as the two above, for the inspector's throughput graph.
    ///
    /// Simulated rates used to be a constant per torrent — to the byte, tick
    /// after tick — which was invisible while every surface showed one number
    /// at a time and became obvious the moment something plotted them: the
    /// graph drew a dead straight line, so the one environment AGENTS.md says
    /// to check UI against could not show the shape the graph exists to draw.
    func testTransferRatesVaryOverTimeInTheSimulator() async throws {
        let engine = SimulationEngine(tickInterval: 0.01, resolveDelay: 0.0)
        let stream = await engine.events
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:wobble",
            saveDirectory: FileManager.default.temporaryDirectory
        )
        for _ in 0..<24 { await engine.step() }

        var downRates: Set<Double> = []
        var upRates: Set<Double> = []
        var batches = 0
        for await event in stream {
            if case .snapshots(let batch) = event {
                for snapshot in batch where snapshot.state == .downloading {
                    downRates.insert(snapshot.downloadRate)
                    upRates.insert(snapshot.uploadRate)
                }
                batches += 1
            }
            if batches >= 24 { break }
        }

        XCTAssertGreaterThan(downRates.count, 4, "download rate is flat under -simulate")
        XCTAssertGreaterThan(upRates.count, 4, "upload rate is flat under -simulate")

        // Uneven, not stalling: a swarm can be lumpy without the transfer
        // dying, and a curve that drops to the baseline every few seconds says
        // the opposite. The zeroes dropped here are the tick a torrent is
        // added on — it is `.downloading` before it has moved a byte.
        let moving = downRates.filter { $0 > 0 }
        guard let slowest = moving.min(), let fastest = moving.max() else {
            return XCTFail("a downloading torrent never reported a rate")
        }
        XCTAssertGreaterThan(slowest, fastest * 0.2, "the rate collapses rather than wobbling")
    }

    /// A finished torrent that is still running is seeding, and the simulator
    /// used to park everything in `.completed` for ever — so nothing ever
    /// uploaded after it finished, the Seeding section stayed empty, and the
    /// inspector's meter reported "Nothing moving" about a torrent whose only
    /// remaining job is to move something.
    func testAFinishedTorrentGoesOnToSeedInTheSimulator() async throws {
        let engine = SimulationEngine(
            tickInterval: 0.01,
            // Absurd on purpose: a tick has to move more than the largest
            // torrent the simulator invents, so the download is over in one
            // and the ticks that follow are all lifecycle.
            baseSpeed: 1024 * 1024 * 1024 * 1024,
            resolveDelay: 0.0
        )
        let stream = await engine.events
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:seedsafter",
            saveDirectory: FileManager.default.temporaryDirectory
        )
        for _ in 0..<12 { await engine.step() }

        var sawSeeding = false
        var seedingUploadRates: Set<Double> = []
        var batches = 0
        for await event in stream {
            if case .snapshots(let batch) = event {
                for snapshot in batch where snapshot.state == .seeding {
                    sawSeeding = true
                    seedingUploadRates.insert(snapshot.uploadRate)
                }
                batches += 1
            }
            if batches >= 12 { break }
        }

        XCTAssertTrue(sawSeeding, "a completed torrent never starts seeding under -simulate")
        XCTAssertFalse(
            seedingUploadRates.allSatisfy { $0 == 0 },
            "a seeding torrent reports no upload, so the meter has nothing to draw"
        )
    }

    /// Two directions that move in lockstep would draw the meter's two halves
    /// as mirror images, which is exactly what a real transfer never looks like.
    func testUploadAndDownloadDoNotMoveInLockstep() async throws {
        let engine = SimulationEngine(tickInterval: 0.01, resolveDelay: 0.0)
        let stream = await engine.events
        _ = try await engine.addMagnet(
            "magnet:?xt=urn:btih:phase",
            saveDirectory: FileManager.default.temporaryDirectory
        )
        for _ in 0..<24 { await engine.step() }

        var ratios: Set<Int> = []
        var batches = 0
        for await event in stream {
            if case .snapshots(let batch) = event {
                for snapshot in batch where snapshot.state == .downloading && snapshot.downloadRate > 0 {
                    // Rounded, so this is testing that the *relationship*
                    // changes rather than that two doubles differ.
                    ratios.insert(Int((snapshot.uploadRate / snapshot.downloadRate * 100).rounded()))
                }
                batches += 1
            }
            if batches >= 24 { break }
        }
        XCTAssertGreaterThan(ratios.count, 3, "upload is a fixed fraction of download")
    }
}
