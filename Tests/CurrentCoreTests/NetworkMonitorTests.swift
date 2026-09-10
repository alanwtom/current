import XCTest
import CurrentCore
@testable import CurrentApp

/// A scripted machine, standing in for the real one.
///
/// The monitor normally reads `getifaddrs` and follows the system's own path
/// updates, which means the states worth testing — a tunnel dying, a tunnel
/// returning under a different name — could only be produced by really
/// connecting and disconnecting a VPN while the tests ran. Handing the monitor
/// its interface list instead is what makes those a test rather than an
/// afternoon.
@MainActor
private final class ScriptedMachine {
    var interfaces: [NetworkInterface] = []

    func monitor() -> NetworkMonitor {
        NetworkMonitor(interfaces: { [self] in interfaces }, watchesSystemPath: false)
    }
}

/// What the app concludes from the state of the machine's connections.
///
/// `NetworkBindingTests` covers the decision itself, on values. This covers the
/// layer above it: whether the monitor notices a change, republishes at the
/// right moments, and — the reason any of this exists — keeps up with a tunnel
/// that macOS has renumbered behind its back.
@MainActor
final class NetworkMonitorTests: XCTestCase {

    // MARK: - Fixtures

    private func wifi(addresses: Set<String> = ["192.168.1.20"]) -> NetworkInterface {
        NetworkInterface(name: "en0", displayName: "Wi-Fi", addresses: addresses)
    }

    private func tunnel(
        _ name: String,
        addresses: Set<String> = ["10.2.0.3"]
    ) -> NetworkInterface {
        NetworkInterface(name: name, addresses: addresses, isPointToPoint: true)
    }

    /// A `utun` macOS has finished with but not yet cleaned up: still listed,
    /// still point-to-point, no address on it. These accumulate until reboot.
    private func deadTunnel(_ name: String) -> NetworkInterface {
        NetworkInterface(name: name, addresses: [], isPointToPoint: true)
    }

    // MARK: - Following a tunnel

    func testBindsToTheTunnelTheSystemIsRoutingThrough() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        XCTAssertEqual(monitor.outcome, .bound(device: "utun4", carriesIPv6: false))
        XCTAssertFalse(monitor.outcome.blocksTransfers)
    }

    func testATunnelThatVanishesBlocksTransfers() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")
        XCTAssertFalse(monitor.outcome.blocksTransfers)

        machine.interfaces = [wifi()]
        monitor.primaryChanged(to: "en0")

        XCTAssertTrue(monitor.outcome.blocksTransfers)
        XCTAssertNil(monitor.outcome.device)
    }

    /// **The case the whole "never store the device name" rule exists for.**
    ///
    /// macOS renumbers `utun` on every reconnect, so the tunnel that comes back
    /// is not the one that went away. A client that remembered `utun4` is
    /// pointed at nothing from the first reconnect onward — bound, by its own
    /// account, to an interface that no longer carries anything.
    func testATunnelReturningUnderANewNameIsFollowed() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")
        XCTAssertEqual(monitor.outcome.device, "utun4")

        machine.interfaces = [wifi()]
        monitor.primaryChanged(to: "en0")
        XCTAssertTrue(monitor.outcome.blocksTransfers)

        // Same VPN, same user, new device name.
        machine.interfaces = [wifi(), tunnel("utun7")]
        monitor.primaryChanged(to: "utun7")

        XCTAssertEqual(monitor.outcome.device, "utun7")
        XCTAssertFalse(monitor.outcome.blocksTransfers)
    }

    /// The reconnect leaves the old `utun` lying around with no address on it.
    /// Counting it as a tunnel would make this look like two VPNs at once, and
    /// the app would refuse to choose rather than following the live one.
    func testTheDeadTunnelLeftBehindIsIgnored() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), deadTunnel("utun4"), tunnel("utun7")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun7")

        XCTAssertEqual(monitor.outcome.device, "utun7")
    }

    /// And with nothing but corpses left, there is no VPN — not a choice
    /// between them.
    func testOnlyDeadTunnelsMeansNoConnection() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), deadTunnel("utun4"), deadTunnel("utun5")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "en0")

        XCTAssertTrue(monitor.outcome.blocksTransfers)
    }

    /// A named interface is resolved against the machine every time too, so the
    /// device being unplugged is caught the same way a tunnel dropping is.
    func testANamedInterfaceThatGoesAwayBlocksTransfers() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi()]

        let monitor = machine.monitor()
        monitor.updateBinding(.named("en0"))
        XCTAssertEqual(monitor.outcome.device, "en0")

        machine.interfaces = []
        monitor.refresh()

        XCTAssertTrue(monitor.outcome.blocksTransfers)
    }

    // MARK: - When it republishes

    /// The outcome drives stopping every transfer in the library, so it must
    /// fire on real change and on nothing else. Interface lists are re-read on
    /// every path update, and a busy machine produces plenty that change
    /// nothing.
    func testTheOutcomeIsPublishedOnlyWhenItChanges() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        var published: [BindingOutcome] = []
        monitor.onOutcomeChanged = { published.append($0) }

        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")
        XCTAssertEqual(published.map(\.device), ["utun4"])

        monitor.refresh()
        monitor.refresh()
        monitor.primaryChanged(to: "utun4")

        XCTAssertEqual(published.map(\.device), ["utun4"], "identical state republished")
    }

    func testEachSideOfAnOutageIsPublishedOnce() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        var published: [Bool] = []
        monitor.onOutcomeChanged = { published.append($0.blocksTransfers) }

        machine.interfaces = [wifi()]
        monitor.primaryChanged(to: "en0")
        monitor.refresh()

        machine.interfaces = [wifi(), tunnel("utun7")]
        monitor.primaryChanged(to: "utun7")
        monitor.refresh()

        XCTAssertEqual(published, [true, false])
    }

    // MARK: - Reading the engine back

    /// Switching where the session may listen tears the old sockets down, and
    /// libtorrent does not always say so — a binding pointed at a device that
    /// isn't there simply goes quiet. Keeping the previous addresses would
    /// leave the pane reporting a live connection that no longer exists, which
    /// is the exact failure this readout is here to catch.
    func testTheEnginesLastReportIsForgottenWhenTheOutcomeChanges() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        monitor.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        XCTAssertTrue(monitor.listen.isListening)

        machine.interfaces = [wifi()]
        monitor.primaryChanged(to: "en0")

        XCTAssertFalse(monitor.listen.isListening)
    }

    func testABindIsConfirmedFromTheAddressTheEngineReports() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        XCTAssertEqual(monitor.isBindingConfirmed, false, "nothing reported yet")

        monitor.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        XCTAssertEqual(monitor.isBindingConfirmed, true)
    }

    /// The whole point of reading the engine rather than the setting: a socket
    /// somewhere else has to read as a leak, not as success.
    func testASocketSomewhereElseIsNotConfirmed() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        monitor.apply(ListenReport(address: "192.168.1.20", port: 6881, succeeded: true))

        XCTAssertEqual(monitor.isBindingConfirmed, false)
    }

    /// A real bind reports its IPv6 socket scoped to the device it is on, and
    /// that suffix is better evidence than any address comparison — the
    /// interface list deliberately excludes link-local, so there would be
    /// nothing to compare it against.
    func testAScopedAddressNamesItsOwnDevice() {
        let machine = ScriptedMachine()
        machine.interfaces = [wifi(), tunnel("utun4")]

        let monitor = machine.monitor()
        monitor.updateBinding(.activeVPN)
        monitor.primaryChanged(to: "utun4")

        monitor.apply(ListenReport(address: "fe80::1%utun4", port: 6881, succeeded: true))

        XCTAssertEqual(monitor.isBindingConfirmed, true)
    }

    // MARK: - What the picker offers

    /// Only interfaces that could actually carry a transfer. A dead `utun` in
    /// the list is a choice that silently stops everything the moment it is
    /// picked.
    func testThePickerOffersOnlyUsableInterfaces() {
        let machine = ScriptedMachine()
        machine.interfaces = [
            wifi(),
            deadTunnel("utun4"),
            tunnel("utun7"),
            NetworkInterface(name: "lo0", addresses: ["127.0.0.1"], isLoopback: true),
        ]

        let monitor = machine.monitor()
        monitor.refresh()

        XCTAssertEqual(monitor.selectableInterfaces.map(\.name), ["en0", "utun7"])
    }
}
