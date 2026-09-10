import Foundation

/// One network interface, reduced to the facts a binding decision needs.
///
/// A value type on purpose. Listing interfaces is I/O and lives in the app;
/// *choosing* between them is the part that has to be right, so it lives here
/// where it can be tested against interface sets that would be a nuisance to
/// reproduce by plugging cables in.
public struct NetworkInterface: Equatable, Sendable, Identifiable {
    public var name: String
    /// What macOS calls this interface in Network settings — "Wi-Fi",
    /// "Thunderbolt Bridge", a VPN's own name. Filled in by the app from
    /// SystemConfiguration where it can be; nil is normal for tunnels, which
    /// often have no configured service behind them.
    public var displayName: String?
    /// Every address currently configured on this interface.
    ///
    /// Kept rather than reduced to a pair of "has IPv4 / has IPv6" flags,
    /// because the engine's own confirmation that it bound where it was told
    /// arrives as an address and has to be matched back against these.
    public var addresses: Set<String>
    public var isUp: Bool
    public var isLoopback: Bool
    /// Point-to-point. Every VPN tunnel on macOS sets this; Wi-Fi and Ethernet
    /// never do, which is half of how a tunnel is recognised below.
    public var isPointToPoint: Bool

    public var id: String { name }

    public init(
        name: String,
        displayName: String? = nil,
        addresses: Set<String> = [],
        isUp: Bool = true,
        isLoopback: Bool = false,
        isPointToPoint: Bool = false
    ) {
        self.name = name
        self.displayName = displayName
        self.addresses = addresses
        self.isUp = isUp
        self.isLoopback = isLoopback
        self.isPointToPoint = isPointToPoint
    }

    /// An IPv6 literal is the one with colons in it; nothing else here does.
    public var hasIPv6: Bool { addresses.contains { $0.contains(":") } }
    public var hasIPv4: Bool { addresses.contains { !$0.contains(":") } }

    /// What to put in front of the user. The device name is always shown
    /// somewhere alongside it — it is the thing that appears in a packet
    /// capture, so hiding it would make the app harder to check up on.
    public var label: String {
        guard let displayName, !displayName.isEmpty else { return name }
        return "\(displayName) (\(name))"
    }

    public var hasAddress: Bool { !addresses.isEmpty }

    /// Whether this is something the app could bind to at all. An interface
    /// that is down, or up with no address on it, cannot carry a transfer —
    /// and macOS keeps dead `utun` entries around until the next reboot, so
    /// "the tunnel exists" is never enough on its own.
    public var isBindable: Bool { isUp && !isLoopback && hasAddress }

    /// Only the distinction the app acts on. Wi-Fi and Ethernet are both just
    /// `.ordinary`: macOS names them `en0`, `en1`, `en2` with no rule about
    /// which is which, so a client that sorted them into "Wi-Fi" and "Wired"
    /// from the name alone would be guessing, and would be wrong on any Mac
    /// with a dock. The real name is what gets shown instead.
    public enum Kind: Equatable, Sendable {
        case tunnel
        case loopback
        case ordinary
    }

    /// Whether this looks like a VPN tunnel.
    ///
    /// Naming plus the point-to-point flag is all macOS offers without private
    /// API, so this is a heuristic and is treated as one: it decides what the
    /// picker *calls* things, and for "my VPN" it is paired with the system's
    /// own routing choice (`NetworkSnapshot.activeTunnel`) rather than trusted
    /// alone. `utun` covers WireGuard, Tailscale and most commercial VPN
    /// clients — and also things that are not a VPN at all, which is exactly
    /// why the name is not the whole test.
    public var kind: Kind {
        if isLoopback { return .loopback }
        let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
        if tunnelPrefixes.contains(where: { name.hasPrefix($0) }) { return .tunnel }
        return isPointToPoint ? .tunnel : .ordinary
    }
}

/// The state of the machine's networking at one moment.
public struct NetworkSnapshot: Equatable, Sendable {
    public var interfaces: [NetworkInterface]
    /// The interface the system is currently routing general traffic through.
    ///
    /// This is the discriminator that makes "my VPN" trustworthy. macOS
    /// promotes a VPN tunnel to primary when it takes over the default route,
    /// so a tunnel that is primary is a tunnel that traffic actually uses —
    /// unlike a `utun` that some other feature left lying around.
    public var primaryName: String?

    public init(interfaces: [NetworkInterface], primaryName: String? = nil) {
        self.interfaces = interfaces
        self.primaryName = primaryName
    }

    public static let empty = NetworkSnapshot(interfaces: [])

    public func interface(named name: String) -> NetworkInterface? {
        interfaces.first { $0.name == name }
    }

    public var bindableInterfaces: [NetworkInterface] {
        interfaces.filter(\.isBindable)
    }

    /// Tunnels that are up and carrying an address.
    public var bindableTunnels: [NetworkInterface] {
        bindableInterfaces.filter { $0.kind == .tunnel }
    }

    /// The tunnel to use when the user has asked for "my VPN".
    ///
    /// Degrades in a stated order rather than guessing:
    ///
    /// 1. The primary interface, if it is a tunnel — the system is routing
    ///    through it, so it is unambiguously *the* VPN.
    /// 2. Otherwise the only bindable tunnel there is. This is the split-tunnel
    ///    case, where the VPN deliberately isn't primary; binding to it is
    ///    still what was asked for.
    /// 3. Otherwise nothing. With two tunnels up and neither primary there is
    ///    no defensible pick, and picking wrong here is the failure that
    ///    matters, so the caller is told to name one instead.
    public var activeTunnel: NetworkInterface? {
        if let primaryName, let primary = interface(named: primaryName),
           primary.kind == .tunnel, primary.isBindable {
            return primary
        }
        let tunnels = bindableTunnels
        return tunnels.count == 1 ? tunnels[0] : nil
    }
}

/// What the user asked the app to confine its traffic to.
///
/// `activeVPN` stores the *intent*, never a device name, and that is the whole
/// point. macOS renumbers `utun` on every reconnect and leaves the old ones
/// behind, so a stored "utun4" is stale the first time the VPN drops and comes
/// back — which is the long-standing complaint about doing this on a Mac in
/// other clients. Resolving the intent against the current snapshot every time
/// is what makes reconnecting a non-event.
public enum NetworkBinding: Equatable, Hashable, Sendable {
    /// Every interface. The app's default, and what it did before this existed.
    case anyInterface
    /// Whatever tunnel is currently carrying traffic.
    case activeVPN
    /// One specific interface, by name.
    case named(String)

    public var isRestricted: Bool { self != .anyInterface }

    // MARK: Persistence
    //
    // Stored as a single string so it goes in the settings table like every
    // other setting. `vpn` is a reserved word here and cannot collide with a
    // device name, because macOS interface names never contain a colon.

    public var storedValue: String {
        switch self {
        case .anyInterface: return ""
        case .activeVPN: return "vpn"
        case .named(let name): return "if:\(name)"
        }
    }

    public init(storedValue: String) {
        if storedValue == "vpn" {
            self = .activeVPN
        } else if storedValue.hasPrefix("if:") {
            let name = String(storedValue.dropFirst(3))
            self = name.isEmpty ? .anyInterface : .named(name)
        } else {
            self = .anyInterface
        }
    }
}

/// The binding resolved against the network as it is right now.
///
/// Three cases rather than an optional device name, so that "asked for a VPN
/// and there isn't one" cannot be quietly handled as "no binding requested".
/// Those two want opposite behaviour — one transfers over everything, the other
/// must transfer over nothing — and an optional would let a caller confuse them.
public enum BindingOutcome: Equatable, Sendable {
    /// No restriction asked for: every interface, as before.
    case unrestricted
    /// Confined to a device that exists right now.
    case bound(device: String, carriesIPv6: Bool)
    /// A restriction was asked for and its interface isn't there. Nothing may
    /// transfer until it comes back.
    case unavailable(reason: String)

    /// The device to confine the engine to, if any.
    public var device: String? {
        if case .bound(let device, _) = self { return device }
        return nil
    }

    /// True when the app must not move any bytes.
    public var blocksTransfers: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// Why things are the way they are. Every automatic behaviour in this app
    /// has to be able to answer that — see AGENTS.md.
    public var explanation: String {
        switch self {
        case .unrestricted:
            return "Using any available connection."
        case .bound(let device, let carriesIPv6):
            let base = "Only using \(device)."
            return carriesIPv6 ? base : base + " This connection has no IPv6, so IPv6 is unused."
        case .unavailable(let reason):
            return reason
        }
    }
}

extension NetworkBinding {
    /// Turns the stored intent into a decision about the network as it is now.
    public func resolve(in snapshot: NetworkSnapshot) -> BindingOutcome {
        switch self {
        case .anyInterface:
            return .unrestricted

        case .activeVPN:
            if let tunnel = snapshot.activeTunnel {
                return .bound(device: tunnel.name, carriesIPv6: tunnel.hasIPv6)
            }
            if snapshot.bindableTunnels.count > 1 {
                return .unavailable(
                    reason: "More than one VPN connection is active, so Current can't tell which one you meant. Choose one by name."
                )
            }
            return .unavailable(
                reason: "No VPN connection found, so nothing will transfer."
            )

        case .named(let name):
            guard let match = snapshot.interface(named: name) else {
                return .unavailable(
                    reason: "\(name) isn't there any more, so nothing will transfer."
                )
            }
            guard match.isBindable else {
                return .unavailable(
                    reason: "\(name) is present but has no address, so nothing will transfer."
                )
            }
            return .bound(device: match.name, carriesIPv6: match.hasIPv6)
        }
    }
}

/// One listen socket's fate, as reported by the engine.
///
/// The engine emits several of these per bind — TCP and UDP, IPv4 and IPv6 —
/// so they are collected rather than read one at a time.
public struct ListenReport: Equatable, Sendable {
    /// The local address the socket bound to, or tried to.
    public var address: String
    public var port: Int
    /// The device libtorrent was aiming at. Empty on success, because the
    /// success notice carries only an address — the app matches it back to a
    /// device itself.
    public var device: String
    public var succeeded: Bool
    /// Technical detail on failure. Not shown to the user as-is.
    public var message: String

    public init(
        address: String, port: Int, device: String = "",
        succeeded: Bool, message: String = ""
    ) {
        self.address = address
        self.port = port
        self.device = device
        self.succeeded = succeeded
        self.message = message
    }
}

/// What the app is *actually* listening on, assembled from the engine's own
/// reports and checked against what the user asked for.
///
/// The check is the point. `intended` is the device the app resolved and sent
/// to the engine; `addresses` is where the engine says it really ended up. When
/// those disagree the app says so rather than showing a reassuring tick.
public struct ListenState: Equatable, Sendable {
    /// Addresses with a live listen socket.
    public var addresses: Set<String>
    /// The most recent failure, if the last thing that happened was one.
    public var lastFailure: String?

    public static let unknown = ListenState(addresses: [], lastFailure: nil)

    public init(addresses: Set<String>, lastFailure: String? = nil) {
        self.addresses = addresses
        self.lastFailure = lastFailure
    }

    public var isListening: Bool { !addresses.isEmpty }

    /// Folds one report in. Successes add an address, failures remove it —
    /// libtorrent re-reports both as interfaces come and go, so this has to
    /// forget as readily as it learns or a dropped tunnel would leave its
    /// address showing as live forever.
    public mutating func apply(_ report: ListenReport) {
        if report.succeeded {
            addresses.insert(report.address)
            lastFailure = nil
        } else {
            addresses.remove(report.address)
            lastFailure = report.message.isEmpty ? "The connection couldn't be opened." : report.message
        }
    }

    /// Whether the engine's live sockets sit on the device the app asked for.
    ///
    /// The engine's success notice names an address and not a device, so this
    /// works backwards from the address in two ways:
    ///
    /// - **A scoped address names its own device.** IPv6 link-local addresses
    ///   come back as `fe80::…%en0`, and that suffix is better evidence than
    ///   any address comparison — so it is checked directly. This is not an
    ///   edge case: every real binding produces one, and an earlier version
    ///   that only compared addresses reported a leak on every single bind
    ///   because the interface list deliberately excludes link-local.
    /// - **Anything else has to be one of the interface's own addresses.**
    ///
    /// `nil` means "can't tell" — nothing has reported yet, or there is no
    /// address to compare against. The UI must not draw that as confirmation;
    /// the whole point of this check is catching the case where a client claims
    /// to be bound while traffic goes elsewhere.
    public func confirms(device: String, addresses deviceAddresses: Set<String>) -> Bool? {
        guard isListening else { return false }

        var unscoped: Set<String> = []
        for address in addresses {
            if let scope = Self.scope(of: address) {
                if scope != device { return false }
            } else {
                unscoped.insert(address)
            }
        }

        // Every socket named this device itself. Nothing left to check.
        guard !unscoped.isEmpty else { return true }
        guard !deviceAddresses.isEmpty else { return nil }
        return unscoped.allSatisfy { deviceAddresses.contains($0) }
    }

    /// The interface named after `%` in a scoped address, if there is one.
    private static func scope(of address: String) -> String? {
        guard let marker = address.firstIndex(of: "%") else { return nil }
        let scope = String(address[address.index(after: marker)...])
        return scope.isEmpty ? nil : scope
    }
}

/// The exposures that stop making sense once traffic is confined to a tunnel.
///
/// Both of these are switched off *for* the user rather than left to them,
/// because both defeat the point of binding in ways that are invisible from
/// inside the app:
///
/// - Asking the router to open a port (UPnP/NAT-PMP) reaches the router over
///   the local network, not the tunnel. It cannot work through the VPN, and the
///   request itself tells the router this Mac is running a torrent client.
/// - Local peer discovery multicasts what is being downloaded to every device
///   on the network, from the real address, whatever the tunnel is doing.
///
/// Returned as a value with reasons attached rather than applied silently, so
/// the settings screen can say why a switch it isn't letting you use is off.
public struct BindingSideEffects: Equatable, Sendable {
    public var disablesPortMapping: Bool
    public var disablesLocalDiscovery: Bool
    public var reasons: [String]

    public static let none = BindingSideEffects(
        disablesPortMapping: false, disablesLocalDiscovery: false, reasons: []
    )

    public init(disablesPortMapping: Bool, disablesLocalDiscovery: Bool, reasons: [String]) {
        self.disablesPortMapping = disablesPortMapping
        self.disablesLocalDiscovery = disablesLocalDiscovery
        self.reasons = reasons
    }

    public static func forBinding(_ binding: NetworkBinding) -> BindingSideEffects {
        guard binding.isRestricted else { return .none }
        return BindingSideEffects(
            disablesPortMapping: true,
            disablesLocalDiscovery: true,
            reasons: [
                "Port mapping is off: it reaches your router over your normal connection, not the VPN.",
                "Local network discovery is off: it announces what you're downloading on your own network.",
            ]
        )
    }
}
