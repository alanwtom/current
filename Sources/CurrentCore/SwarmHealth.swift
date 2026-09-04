import Foundation

/// How well-served a torrent's swarm is — and, crucially, whether that is
/// something the app actually knows.
///
/// **The `unknown` case is the point of this type.** It used to be three cases
/// built from `connectedSeeds`, the number of seeds this machine has an open
/// connection to, and that number is zero in two entirely ordinary situations:
/// the torrent is paused, or it was added a moment ago and hasn't announced
/// yet. Both read as "rare". The bug that surfaced it was a torrent with 335
/// seeders on its tracker page sitting in the library labelled *Rare · 0
/// seeds*, with an amber callout offering to preserve it.
///
/// That was not only wrong on screen. `SeedPolicy` keeps seeding a rare torrent
/// past its goal, and `CleanupPlanner` refuses to clean one — so a measurement
/// artefact was changing what the app *did*.
public enum SwarmHealth: Equatable, Sendable {
    case healthy
    case moderate
    case rare
    /// Nothing has reported on this swarm yet. Say nothing rather than guess.
    case unknown

    /// Judges the swarm from the best evidence available, in order of how much
    /// it can be trusted:
    ///
    /// 1. `swarmSeeds` — a tracker or the DHT counting the whole swarm. This is
    ///    the real answer when we have it, and it stays valid while paused.
    /// 2. `knownSeeds` — seeds in our peer list. Second best: it comes from an
    ///    announce, so a positive number is real evidence.
    /// 3. `connectedSeeds` — who we're actually talking to. Only ever used to
    ///    *confirm* seeds exist, never to conclude they don't.
    ///
    /// With none of the three saying anything, the answer is `unknown`. Note
    /// what is deliberately absent: there is no path from "zero connections" to
    /// `rare`. Absence of evidence isn't evidence of an empty swarm.
    public init(swarmSeeds: Int?, knownSeeds: Int = 0, connectedSeeds: Int = 0) {
        if let swarmSeeds, swarmSeeds >= 0 {
            self = Self.judge(seeds: swarmSeeds)
        } else if knownSeeds > 0 {
            self = Self.judge(seeds: knownSeeds)
        } else if connectedSeeds > 0 {
            self = Self.judge(seeds: connectedSeeds)
        } else {
            self = .unknown
        }
    }

    public init(swarm: SwarmSummary) {
        self.init(
            swarmSeeds: swarm.swarmSeeds,
            knownSeeds: swarm.knownSeeds,
            connectedSeeds: swarm.connectedSeeds
        )
    }

    private static func judge(seeds: Int) -> SwarmHealth {
        switch seeds {
        case ..<3: return .rare
        case ..<10: return .moderate
        default: return .healthy
        }
    }

    /// True when the app has something real to say. The UI shows the chip and
    /// the callout only then.
    public var isKnown: Bool { self != .unknown }

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .moderate: return "Moderate"
        case .rare: return "Rare"
        case .unknown: return "Unknown"
        }
    }

    /// Plain-language explanation shown in the inspector. Never shames the user.
    public var explanation: String {
        switch self {
        case .healthy:
            return "Plenty of complete sources exist. This torrent doesn't need you to stay available."
        case .moderate:
            return "A normal number of complete sources. Standard seeding policy applies."
        case .rare:
            return "Only a few complete sources are available. Keeping this torrent seeded helps preserve it."
        case .unknown:
            return "No tracker has reported on this swarm yet, so there is nothing to judge."
        }
    }
}
