import Foundation

public enum SwarmHealth: Equatable, Sendable {
    case healthy
    case moderate
    case rare

    public init(seeds: Int) {
        switch seeds {
        case ..<3: self = .rare
        case ..<10: self = .moderate
        default: self = .healthy
        }
    }

    public var label: String {
        switch self {
        case .healthy: return "Healthy"
        case .moderate: return "Moderate"
        case .rare: return "Rare"
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
        }
    }
}
