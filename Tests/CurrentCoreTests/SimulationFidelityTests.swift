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
}
