import Foundation

/// A seeding goal expressed in plain terms.
public struct SeedGoal: Hashable, Codable, Sendable {
    /// Stop once this share ratio is reached (uploaded ÷ downloaded).
    public var targetRatio: Double?
    /// …and after at least this much time spent seeding.
    public var minimumSeedSeconds: TimeInterval?

    public init(targetRatio: Double?, minimumSeedSeconds: TimeInterval?) {
        self.targetRatio = targetRatio
        self.minimumSeedSeconds = minimumSeedSeconds
    }

    public static func == (lhs: SeedGoal, rhs: SeedGoal) -> Bool {
        lhs.targetRatio == rhs.targetRatio && lhs.minimumSeedSeconds == rhs.minimumSeedSeconds
    }
}

public enum SeedPolicy: Hashable, Codable, Sendable {
    /// Ratio ≥ 1.0 and 24 hours of seed time, then stop.
    case balanced
    /// Balanced rules, but keeps rare torrents alive even after the goal is met.
    case helpful
    /// Keep seeding forever.
    case archive
    /// Seed to the goal, then make the torrent eligible for cleanup.
    case temporary
    /// User-defined goal.
    case custom(SeedGoal)

    public var goal: SeedGoal {
        switch self {
        case .balanced, .helpful: return SeedGoal(targetRatio: 1.0, minimumSeedSeconds: 24 * 3600)
        case .archive: return SeedGoal(targetRatio: nil, minimumSeedSeconds: nil)
        case .temporary: return SeedGoal(targetRatio: 1.0, minimumSeedSeconds: nil)
        case .custom(let goal): return goal
        }
    }

    public var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .helpful: return "Helpful"
        case .archive: return "Archive"
        case .temporary: return "Temporary"
        case .custom: return "Custom"
        }
    }

    public var summary: String {
        switch self {
        case .balanced:
            return "Stops after a 1.0× share ratio and 24 hours of seeding."
        case .helpful:
            return "Balanced rules, but stays available while a torrent is rare."
        case .archive:
            return "Keeps seeding indefinitely to preserve the swarm."
        case .temporary:
            return "Seeds until the goal is met, then becomes ready for cleanup."
        case .custom(let goal):
            var parts: [String] = []
            if let r = goal.targetRatio { parts.append("a \(ByteFormatting.ratio(r)) ratio") }
            if let t = goal.minimumSeedSeconds {
                parts.append("\(ByteFormatting.duration(t)) of seed time")
            }
            if parts.isEmpty { return "Never stops automatically." }
            return "Stops after " + parts.joined(separator: " and ") + "."
        }
    }

    public static let defaultPolicy: SeedPolicy = .balanced
}

public struct SeedDecision: Equatable, Sendable {
    public var shouldStop: Bool
    public var goalMet: Bool
    public var reasons: [String]

    public init(shouldStop: Bool, goalMet: Bool, reasons: [String]) {
        self.shouldStop = shouldStop
        self.goalMet = goalMet
        self.reasons = reasons
    }
}

public enum SeedEvaluator {
    /// Evaluates whether automation should pause this torrent's seeding.
    ///
    /// - Parameters:
    ///   - snapshot: current torrent state
    ///   - policy: the policy assigned to the torrent
    ///   - now: current time (injected for testability)
    public static func evaluate(
        snapshot: TorrentSnapshot,
        policy: SeedPolicy,
        now: Date = Date()
    ) -> SeedDecision {
        let goal = policy.goal

        if case .archive = policy {
            return SeedDecision(
                shouldStop: false,
                goalMet: false,
                reasons: ["Archive policy keeps this torrent seeded."]
            )
        }

        guard snapshot.state.isComplete else {
            return SeedDecision(shouldStop: false, goalMet: false, reasons: [])
        }

        var ratioMet = true
        var timeMet = true
        var reasons: [String] = []
        var unmet: [String] = []

        if let targetRatio = goal.targetRatio {
            let ratio = snapshot.shareRatio
            if ratio >= targetRatio {
                reasons.append("Ratio reached \(ByteFormatting.ratio(ratio))")
            } else {
                ratioMet = false
                unmet.append("ratio is \(ByteFormatting.ratio(ratio)) (target \(ByteFormatting.ratio(targetRatio)))")
            }
        }

        if let minimum = goal.minimumSeedSeconds {
            if snapshot.activeSeedSeconds >= minimum {
                reasons.append("Seeded for \(ByteFormatting.duration(snapshot.activeSeedSeconds))")
            } else {
                timeMet = false
                unmet.append("seeded \(ByteFormatting.duration(snapshot.activeSeedSeconds)) of \(ByteFormatting.duration(minimum))")
            }
        }

        let goalMet = ratioMet && timeMet

        if !goalMet {
            return SeedDecision(
                shouldStop: false,
                goalMet: false,
                reasons: ["Still seeding because the " + unmet.joined(separator: " and ") + "."]
            )
        }

        // Goal is met. Helpful mode overrides stopping for rare swarms.
        if case .helpful = policy, SwarmHealth(seeds: snapshot.swarm.connectedSeeds) == .rare {
            var kept = reasons
            kept.append("Only \(snapshot.swarm.connectedSeeds) seed\(snapshot.swarm.connectedSeeds == 1 ? "" : "s") remain — Helpful mode kept this torrent active")
            return SeedDecision(shouldStop: false, goalMet: true, reasons: kept)
        }

        if !reasons.contains(where: { $0.contains("Swarm") }),
           SwarmHealth(seeds: snapshot.swarm.connectedSeeds) == .healthy {
            reasons.append("Swarm is healthy")
        }

        if case .temporary = policy {
            reasons.append("Ready for cleanup under the Temporary policy")
        }

        return SeedDecision(shouldStop: true, goalMet: true, reasons: reasons)
    }
}
