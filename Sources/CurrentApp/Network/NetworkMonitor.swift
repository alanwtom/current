import Foundation
import Combine
import Network
import SystemConfiguration
import CurrentCore

/// Watches the machine's network interfaces and resolves the user's binding
/// choice against them.
///
/// Deliberately event-driven rather than polled. Everything else in the app
/// that carries live data is coalesced onto a timer to keep the window from
/// re-measuring itself once a second (see `SidebarCounts`), but network changes
/// aren't periodic — a VPN connecting is a short burst and then silence for
/// hours. What matters here instead is that nothing is published unless it
/// genuinely changed, so a burst of identical path updates moves nothing on
/// screen. That, plus the readout being a fixed size, is what keeps this out of
/// the layout-churn trap.
@MainActor
final class NetworkMonitor: ObservableObject {

    /// The interfaces as they are right now.
    @Published private(set) var snapshot: NetworkSnapshot = .empty
    /// The user's choice resolved against that snapshot.
    @Published private(set) var outcome: BindingOutcome = .unrestricted
    /// What the engine says it actually managed to listen on.
    @Published private(set) var listen: ListenState = .unknown

    /// Called when the resolved outcome changes, so the engine can be told and
    /// — when a binding has been lost — transfers can be stopped.
    var onOutcomeChanged: ((BindingOutcome) -> Void)?

    /// Where the interface list comes from.
    ///
    /// The app asks the real machine. A test hands over a scripted list, and
    /// that is the only way to reach the case this whole design exists for —
    /// a tunnel dying and coming back under a different name. You cannot ask
    /// the OS to stage that, and every bug worth catching here lives in what
    /// the app does across the transition rather than at either end of it.
    typealias InterfaceSource = @MainActor () -> [NetworkInterface]

    private var binding: NetworkBinding = .anyInterface
    private let interfaceSource: InterfaceSource
    private let pathMonitor: NWPathMonitor?
    private let queue = DispatchQueue(label: "com.current.network-monitor")
    private var primaryName: String?

    /// - Parameters:
    ///   - interfaces: what the machine looks like. Defaults to asking the OS.
    ///   - watchesSystemPath: whether to follow the system's own choice of
    ///     primary interface. A test turns this off, because otherwise a VPN
    ///     connecting on the machine running the tests would overwrite the
    ///     scripted state part-way through and fail it for no reason.
    init(
        interfaces: @escaping InterfaceSource = NetworkMonitor.systemInterfaces,
        watchesSystemPath: Bool = true
    ) {
        self.interfaceSource = interfaces
        self.pathMonitor = watchesSystemPath ? NWPathMonitor() : nil

        if let pathMonitor {
            pathMonitor.pathUpdateHandler = { path in
                // Only the interface *name* crosses the queue boundary. `NWPath`
                // and `NWInterface` are reference-backed and have no business being
                // handed to the main actor.
                //
                // `availableInterfaces` is ordered by the system's own preference
                // for the default route, so the first is the primary — and when a
                // VPN takes over the default route, macOS makes the tunnel primary.
                // That is the fact that makes "my VPN" mean something specific.
                let primary = path.availableInterfaces.first?.name
                Task { @MainActor [weak self] in
                    self?.primaryChanged(to: primary)
                }
            }
            pathMonitor.start(queue: queue)
        }
        refresh()
    }

    deinit {
        pathMonitor?.cancel()
    }

    // MARK: - Inputs

    /// Points the monitor at a different binding choice.
    func updateBinding(_ binding: NetworkBinding) {
        guard binding != self.binding else { return }
        self.binding = binding
        // The interface list is re-read rather than reused: turning this on is
        // exactly when a stale list would be most misleading.
        refresh()
    }

    /// Folds in one of the engine's listen reports.
    func apply(_ report: ListenReport) {
        var next = listen
        next.apply(report)
        if next != listen { listen = next }
    }

    /// Re-reads the interface list and re-resolves.
    func refresh() {
        let next = NetworkSnapshot(
            interfaces: interfaceSource(),
            primaryName: primaryName
        )
        if next != snapshot { snapshot = next }
        recomputeOutcome()
    }

    /// Points the monitor at a different primary interface, the way the
    /// system's path monitor does when a tunnel takes over the default route.
    /// Not private so a test can stage that handover; the app never calls it.
    func primaryChanged(to name: String?) {
        primaryName = name
        refresh()
    }

    private func recomputeOutcome() {
        let next = binding.resolve(in: snapshot)
        guard next != outcome else { return }
        outcome = next

        // Forget what the engine last reported, because the engine is about to
        // be reconfigured and its old sockets are no longer the answer.
        //
        // This is not tidiness. Changing where the session may listen closes
        // the previous sockets, and libtorrent does *not* always announce that
        // — a binding switched to a device that doesn't exist simply goes
        // quiet. Keeping the old addresses would leave the readout claiming a
        // live connection that had already been torn down, which is precisely
        // the "screen says one thing, traffic does another" failure this whole
        // feature exists to be able to detect.
        listen = .unknown

        onOutcomeChanged?(next)
    }

    // MARK: - Reading back what really happened

    /// Whether the engine's live sockets are on the device it was told to use.
    ///
    /// `nil` means "can't tell yet" — no listen report has arrived, or the
    /// interface has no address to compare against. The UI must not draw that
    /// as confirmation; the whole reason this exists is that other clients show
    /// a reassuring state while traffic goes somewhere else.
    var isBindingConfirmed: Bool? {
        guard case .bound(let device, _) = outcome else { return nil }
        guard let interface = snapshot.interface(named: device) else { return false }
        return listen.confirms(device: device, addresses: interface.addresses)
    }

    /// Interfaces worth offering in the picker.
    var selectableInterfaces: [NetworkInterface] {
        snapshot.bindableInterfaces
    }

    // MARK: - Enumeration

    /// Every interface the OS will admit to, with its addresses and flags.
    ///
    /// The default `InterfaceSource`, and the one layer of this file that no
    /// test can stand in for: it is the translation from what the machine
    /// really has to the value everything downstream reasons about.
    static func systemInterfaces() -> [NetworkInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        // One interface appears once per address, so entries are merged by name.
        var byName: [String: NetworkInterface] = [:]
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let record = pointer.pointee
            let name = String(cString: record.ifa_name)
            let flags = record.ifa_flags

            var entry = byName[name] ?? NetworkInterface(
                name: name,
                isUp: flags & UInt32(IFF_UP) != 0,
                isLoopback: flags & UInt32(IFF_LOOPBACK) != 0,
                isPointToPoint: flags & UInt32(IFF_POINTOPOINT) != 0
            )
            if let address = record.ifa_addr,
               let text = presentableAddress(address) {
                entry.addresses.insert(text)
            }
            byName[name] = entry
        }

        let labels = displayNames()
        return byName.values
            .map { interface in
                var copy = interface
                copy.displayName = labels[interface.name]
                return copy
            }
            .sorted { $0.name < $1.name }
    }

    /// One address as text, or nil if it isn't one worth recording.
    ///
    /// Link-local addresses are dropped, and that is load-bearing rather than
    /// tidiness: **every** interface on macOS carries an `fe80::` address, so
    /// counting those would make "this connection has IPv6" true everywhere and
    /// the app would stop warning about the one case that matters — an
    /// IPv4-only tunnel, where IPv6 traffic would go straight around it. A
    /// self-assigned `169.254` address means DHCP never answered, which is not
    /// a working connection either.
    private static func presentableAddress(
        _ address: UnsafeMutablePointer<sockaddr>
    ) -> String? {
        let family = address.pointee.sa_family
        guard family == UInt8(AF_INET) || family == UInt8(AF_INET6) else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(
            address, socklen_t(address.pointee.sa_len),
            &host, socklen_t(host.count),
            nil, 0, NI_NUMERICHOST
        ) == 0 else { return nil }

        // IPv6 comes back with a scope suffix on some interfaces ("%utun6"),
        // which is not part of the address libtorrent will report back.
        let text = String(cString: host)
        let bare = text.split(separator: "%").first.map(String.init) ?? text

        let lowered = bare.lowercased()
        let linkLocal = ["fe8", "fe9", "fea", "feb"]
        if linkLocal.contains(where: { lowered.hasPrefix($0) }) { return nil }
        if lowered.hasPrefix("169.254") { return nil }
        return bare
    }

    /// What macOS calls each interface in Network settings — "Wi-Fi",
    /// "Thunderbolt Bridge". Tunnels usually have no entry here, which is why
    /// the device name is always shown too rather than only as a fallback.
    private static func displayNames() -> [String: String] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return [:]
        }
        var result: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let label = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            result[bsd] = label
        }
        return result
    }
}
