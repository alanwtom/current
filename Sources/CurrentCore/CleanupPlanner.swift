import Foundation

public struct CleanupCandidate: Identifiable, Equatable, Sendable {
    public var id: TorrentID { snapshot.id }
    public var snapshot: TorrentSnapshot
    /// Higher means safer and more sensible to remove first.
    public var score: Double
    public var reasons: [String]
    public var reclaimableBytes: Int64

    public static func == (lhs: CleanupCandidate, rhs: CleanupCandidate) -> Bool {
        lhs.id == rhs.id && lhs.score == rhs.score && lhs.reasons == rhs.reasons
    }
}

/// A torrent that fails the safety gate, with an explanation of what keeps it.
public struct KeptTorrent: Identifiable, Equatable, Sendable {
    public var id: TorrentID { snapshot.id }
    public var snapshot: TorrentSnapshot
    public var reasons: [String]
}

public struct CleanupPlan: Equatable, Sendable {
    public var candidates: [CleanupCandidate]
    public var kept: [KeptTorrent]

    public var reclaimableBytes: Int64 {
        candidates.reduce(0) { $0 + $1.reclaimableBytes }
    }

    public static let empty = CleanupPlan(candidates: [], kept: [])

    public func candidatesToReach(freeBytesTarget: Int64) -> [CleanupCandidate] {
        guard freeBytesTarget > 0 else { return [] }
        var total: Int64 = 0
        var result: [CleanupCandidate] = []
        for candidate in candidates {
            result.append(candidate)
            total += candidate.reclaimableBytes
            if total >= freeBytesTarget { break }
        }
        return result
    }
}

public enum CleanupExclusion: String, Sendable {
    case pinned = "Pinned by you"
    case stillTransferring = "Currently transferring data"
    case rareSwarm = "Rare torrent — automatic cleanup leaves these alone"
    case seedGoalUnmet = "Its seeding goal isn't reached yet"
    case incomplete = "Not fully downloaded"
    case filesMissing = "Its files aren't on disk anymore"
    case sharedWithOther = "Its files are shared with another torrent"
}

/// Ranks completed downloads by how safely they can be removed.
///
/// Eligibility is a strict safety gate; ranking then orders everything that
/// passed it so the least valuable content goes first. Every decision carries
/// plain-language reasons.
public enum CleanupPlanner {

    public static func plan(
        snapshots: [TorrentSnapshot],
        policies: [TorrentID: SeedPolicy],
        now: Date = Date()
    ) -> CleanupPlan {
        let directoriesInUse = Dictionary(grouping: snapshots, by: { $0.saveDirectory })
            .compactMapValues { group -> Bool in group.count > 1 }

        var candidates: [CleanupCandidate] = []
        var kept: [KeptTorrent] = []

        for snapshot in snapshots {
            let policy = policies[snapshot.id] ?? .defaultPolicy
            var exclusions: [CleanupExclusion] = []

            switch snapshot.state {
            case .seeding, .completed:
                break
            case .failed(let failure):
                // Failed torrents are never touched by automation.
                _ = failure
                kept.append(KeptTorrent(snapshot: snapshot, reasons: ["Needs your attention"]))
                continue
            default:
                exclusions.append(.incomplete)
            }

            if !snapshot.hasMetadata {
                exclusions.append(.incomplete)
            }

            if snapshot.pinned {
                exclusions.append(.pinned)
            }

            if snapshot.state.isActive && (snapshot.downloadRate > 1 || snapshot.uploadRate > 1) {
                exclusions.append(.stillTransferring)
            }

            if directoriesInUse[snapshot.saveDirectory] == true {
                exclusions.append(.sharedWithOther)
            }

            let decision = SeedEvaluator.evaluate(snapshot: snapshot, policy: policy, now: now)
            if !snapshot.state.isComplete {
                // Incomplete already recorded above; skip goal evaluation noise.
            } else if !decision.goalMet {
                exclusions.append(.seedGoalUnmet)
            } else if case .archive = policy {
                exclusions.append(.seedGoalUnmet)
            }

            // A swarm we can't assess is excluded too, and that is on purpose:
            // this gate decides what the app removes from disk on its own, and
            // the conservative answer to "is this torrent rare?" when nobody
            // has told us is *don't touch it*. It is the same behaviour as
            // before by accident — every paused torrent used to read as rare —
            // except now it is a decision rather than a measurement artefact.
            let health = SwarmHealth(swarm: snapshot.swarm)
            if health == .rare || health == .unknown {
                exclusions.append(.rareSwarm)
            }

            if !exclusions.isEmpty {
                kept.append(
                    KeptTorrent(
                        snapshot: snapshot,
                        reasons: exclusions.map(\.rawValue)
                    )
                )
                continue
            }

            candidates.append(score(snapshot: snapshot, health: health, now: now))
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.snapshot.name.localizedCaseInsensitiveCompare(rhs.snapshot.name) == .orderedAscending
        }

        return CleanupPlan(candidates: candidates, kept: kept)
    }

    static func score(snapshot: TorrentSnapshot, health: SwarmHealth, now: Date) -> CleanupCandidate {
        var reasons: [String] = []

        let completedAgeDays = days(since: snapshot.completedAt ?? snapshot.addedAt, now: now)
        let ageComponent = min(completedAgeDays / 120, 1)
        if completedAgeDays >= 30 {
            reasons.append(ageDescription(completedAgeDays) + " old")
        }

        let sizeComponent = sizeWeight(snapshot.totalBytes)
        if snapshot.totalBytes > 5 * gigabyte {
            reasons.append("\(ByteFormatting.bytes(snapshot.totalBytes)) of space")
        }

        let idleDays = days(since: snapshot.lastActivityAt ?? snapshot.completedAt ?? snapshot.addedAt, now: now)
        let idleComponent = min(idleDays / 45, 1)
        if idleDays >= 14 {
            reasons.append("no activity for " + ageDescription(idleDays))
        }

        let ratio = snapshot.shareRatio
        let ratioComponent = ratio.isFinite ? min(ratio / 2.0, 1) : 1
        if ratio.isFinite && ratio >= 1 {
            reasons.append("shared \(ByteFormatting.ratio(ratio)) back")
        }

        let healthComponent: Double
        switch health {
        case .healthy:
            healthComponent = 1
            // The swarm's own size, not our connection count — that's the
            // number a tracker page shows, and the only one worth quoting.
            if let seeds = snapshot.swarm.swarmSeeds {
                reasons.append("Swarm is healthy (\(seeds) seeds)")
            } else {
                reasons.append("Swarm is healthy")
            }
        case .moderate:
            healthComponent = 0.4
        case .rare:
            healthComponent = 0
        case .unknown:
            // Never reached from `plan` — an unknown swarm is excluded by the
            // gate above and never ranked. Scored neutrally so that a future
            // caller can't get a silently flattering result.
            healthComponent = 0
        }

        let score =
            ageComponent * 0.28
            + sizeComponent * 0.22
            + idleComponent * 0.20
            + ratioComponent * 0.12
            + healthComponent * 0.18

        return CleanupCandidate(
            snapshot: snapshot,
            score: score,
            reasons: reasons,
            reclaimableBytes: max(snapshot.selectedBytes, 0)
        )
    }

    // MARK: - Helpers

    static let gigabyte: Int64 = 1_000_000_000

    static func days(since date: Date, now: Date) -> Double {
        max(0, now.timeIntervalSince(date) / 86_400)
    }

    static func ageDescription(_ days: Double) -> String {
        if days < 1 { return "<1 day" }
        if days < 31 { return "\(Int(days)) day\(Int(days) == 1 ? "" : "s")" }
        if days < 365 { return "\(Int(days / 30)) month\(Int(days / 30) == 1 ? "" : "s")" }
        return "\(Int(days / 365)) year\(Int(days / 365) == 1 ? "" : "s")"
    }

    /// Logarithmic so a 100 GB torrent outranks 10 GB, but 2 GB vs 3 GB doesn't.
    static func sizeWeight(_ bytes: Int64) -> Double {
        guard bytes > 0 else { return 0 }
        let value = log2(Double(bytes) / Double(50 * 1024 * 1024))
        return min(max(value / 11, 0), 1)
    }
}
