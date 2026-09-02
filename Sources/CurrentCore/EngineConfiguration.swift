import Foundation

/// Bytes per second, where **0 means unlimited** — libtorrent's own convention,
/// kept rather than translated so there is no chance of a nil/zero mix-up at
/// the boundary.
public struct RateLimits: Equatable, Sendable {
    public var download: Int
    public var upload: Int

    public init(download: Int, upload: Int) {
        self.download = max(0, download)
        self.upload = max(0, upload)
    }

    public static let unlimited = RateLimits(download: 0, upload: 0)

    public var isUnlimited: Bool { download == 0 && upload == 0 }
}

/// How hard to insist on protocol encryption. Torrent clients universally offer
/// these three, and some ISPs throttle unencrypted peer traffic, so "required"
/// has to be reachable even though it shrinks the usable swarm.
public enum EncryptionPolicy: String, Equatable, Sendable, CaseIterable {
    case allowed
    case preferred
    case required

    public var title: String {
        switch self {
        case .allowed: return "Allow both"
        case .preferred: return "Prefer encrypted"
        case .required: return "Require encrypted"
        }
    }

    public var detail: String {
        switch self {
        case .allowed: return "Connect either way. Largest possible swarm."
        case .preferred: return "Encrypt when the peer supports it."
        case .required: return "Refuse unencrypted peers. Smaller swarm, and some peers become unreachable."
        }
    }
}

/// Everything the session-wide engine settings can be set to. One struct and
/// one `apply` call, rather than a method per knob, so adding a setting doesn't
/// widen the engine protocol every time.
public struct EngineConfiguration: Equatable, Sendable {
    public var rateLimits: RateLimits
    public var maxConnections: Int
    public var maxUploadSlots: Int
    /// Queue caps. Torrents beyond these wait rather than all starting at once
    /// and splitting the line into uselessness.
    public var maxActiveDownloads: Int
    public var maxActiveSeeds: Int
    /// 0 asks the OS for any free port.
    public var listenPort: Int
    public var isDHTEnabled: Bool
    public var isLocalDiscoveryEnabled: Bool
    public var isPortMappingEnabled: Bool
    public var encryption: EncryptionPolicy

    public init(
        rateLimits: RateLimits = .unlimited,
        maxConnections: Int = 200,
        maxUploadSlots: Int = 8,
        maxActiveDownloads: Int = 5,
        maxActiveSeeds: Int = 5,
        listenPort: Int = 6881,
        isDHTEnabled: Bool = true,
        isLocalDiscoveryEnabled: Bool = true,
        isPortMappingEnabled: Bool = true,
        encryption: EncryptionPolicy = .preferred
    ) {
        self.rateLimits = rateLimits
        self.maxConnections = max(1, maxConnections)
        self.maxUploadSlots = max(1, maxUploadSlots)
        self.maxActiveDownloads = max(1, maxActiveDownloads)
        self.maxActiveSeeds = max(0, maxActiveSeeds)
        self.listenPort = listenPort
        self.isDHTEnabled = isDHTEnabled
        self.isLocalDiscoveryEnabled = isLocalDiscoveryEnabled
        self.isPortMappingEnabled = isPortMappingEnabled
        self.encryption = encryption
    }
}

/// Decides which set of rate limits is in force right now.
///
/// Two things can ask for the slower set: the user flipping it on directly, and
/// the machine running on battery. Keeping that decision here — pure, and
/// tested — is what makes the battery setting real. It shipped as a toggle in
/// Settings that was wired to nothing at all: you could turn it on and off and
/// no code anywhere read it.
public struct BandwidthPolicy: Equatable, Sendable {
    public var normal: RateLimits
    /// The slower set. Called "reduced" rather than "turtle" so the intent
    /// survives without the metaphor.
    public var reduced: RateLimits
    /// Reduced limits switched on by hand, regardless of power source.
    public var isReducedForced: Bool
    /// Reduce automatically while unplugged.
    public var reduceOnBattery: Bool

    public init(
        normal: RateLimits = .unlimited,
        reduced: RateLimits = RateLimits(download: 1_000_000, upload: 250_000),
        isReducedForced: Bool = false,
        reduceOnBattery: Bool = false
    ) {
        self.normal = normal
        self.reduced = reduced
        self.isReducedForced = isReducedForced
        self.reduceOnBattery = reduceOnBattery
    }

    public func isReducedActive(onBattery: Bool) -> Bool {
        isReducedForced || (reduceOnBattery && onBattery)
    }

    public func effectiveLimits(onBattery: Bool) -> RateLimits {
        isReducedActive(onBattery: onBattery) ? reduced : normal
    }

    /// Why the current limits are what they are. Every automatic behaviour in
    /// this app has to be able to answer that — see AGENTS.md.
    public func explanation(onBattery: Bool) -> String {
        if isReducedForced {
            return "Reduced speed is switched on."
        }
        if reduceOnBattery && onBattery {
            return "Running on battery, so speeds are reduced."
        }
        if normal.isUnlimited {
            return "No speed limit."
        }
        return "Using your normal speed limits."
    }
}
