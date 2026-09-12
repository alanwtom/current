import XCTest
@testable import CurrentCore

/// Tests for confining transfers to one network connection.
///
/// The interesting cases are all ones that are a nuisance to produce by hand —
/// a tunnel that is up but has no address, two VPNs at once, a `utun` that
/// macOS left behind after a disconnect. Those are exactly the states that make
/// this feature lie to you if it gets them wrong, so they are the ones written
/// down here rather than the happy path.
final class NetworkBindingTests: XCTestCase {

    // MARK: - Fixtures

    private func wifi(addresses: Set<String> = ["192.168.1.20"]) -> NetworkInterface {
        NetworkInterface(name: "en0", displayName: "Wi-Fi", addresses: addresses)
    }

    private func tunnel(
        _ name: String = "utun6",
        addresses: Set<String> = ["10.2.0.3"],
        isUp: Bool = true
    ) -> NetworkInterface {
        NetworkInterface(
            name: name, addresses: addresses, isUp: isUp, isPointToPoint: true
        )
    }

    // MARK: - Nothing asked for

    func testAnyConnectionPlacesNoRestriction() {
        let snapshot = NetworkSnapshot(interfaces: [wifi()], primaryName: "en0")
        let outcome = NetworkBinding.anyInterface.resolve(in: snapshot)

        XCTAssertEqual(outcome, .unrestricted)
        XCTAssertNil(outcome.device)
        XCTAssertFalse(outcome.blocksTransfers)
    }

    // MARK: - "My VPN"

    func testVPNBindsToTheTunnelTheSystemIsRoutingThrough() {
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(), tunnel()], primaryName: "utun6"
        )

        XCTAssertEqual(
            NetworkBinding.activeVPN.resolve(in: snapshot),
            .bound(device: "utun6", carriesIPv6: false)
        )
    }

    /// Split tunnelling: the VPN deliberately isn't primary, but it is the only
    /// tunnel there is, so binding to it is unambiguously what was asked for.
    func testVPNBindsToTheOnlyTunnelEvenWhenItIsNotPrimary() {
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(), tunnel()], primaryName: "en0"
        )

        XCTAssertEqual(
            NetworkBinding.activeVPN.resolve(in: snapshot),
            .bound(device: "utun6", carriesIPv6: false)
        )
    }

    func testVPNRefusesToGuessBetweenTwoTunnels() {
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(), tunnel("utun6"), tunnel("utun7")],
            primaryName: "en0"
        )
        let outcome = NetworkBinding.activeVPN.resolve(in: snapshot)

        XCTAssertTrue(outcome.blocksTransfers)
        XCTAssertNil(outcome.device)
        XCTAssertTrue(
            outcome.explanation.contains("More than one"),
            "The reason should say why it won't pick: \(outcome.explanation)"
        )
    }

    /// Two tunnels is fine as long as the system has told us which one counts.
    func testVPNUsesThePrimaryTunnelWhenThereAreTwo() {
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(), tunnel("utun6"), tunnel("utun7")],
            primaryName: "utun7"
        )

        XCTAssertEqual(
            NetworkBinding.activeVPN.resolve(in: snapshot),
            .bound(device: "utun7", carriesIPv6: false)
        )
    }

    func testVPNWithNoTunnelStopsEverything() {
        let snapshot = NetworkSnapshot(interfaces: [wifi()], primaryName: "en0")
        let outcome = NetworkBinding.activeVPN.resolve(in: snapshot)

        XCTAssertTrue(outcome.blocksTransfers)
        XCTAssertNil(outcome.device)
    }

    /// The macOS trap this whole design exists for: disconnecting a VPN leaves
    /// the `utun` device behind with no address on it until the next reboot. A
    /// client that only checked whether the interface existed would bind to a
    /// dead tunnel and report itself protected.
    func testAbandonedTunnelWithNoAddressIsNotUsable() {
        let stale = tunnel("utun4", addresses: [])
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(), stale], primaryName: "en0"
        )

        XCTAssertFalse(stale.isBindable)
        XCTAssertTrue(NetworkBinding.activeVPN.resolve(in: snapshot).blocksTransfers)
    }

    func testTunnelThatIsDownIsNotUsable() {
        let down = tunnel("utun6", isUp: false)
        let snapshot = NetworkSnapshot(interfaces: [wifi(), down], primaryName: "en0")

        XCTAssertFalse(down.isBindable)
        XCTAssertTrue(NetworkBinding.activeVPN.resolve(in: snapshot).blocksTransfers)
    }

    // MARK: - A named connection

    func testNamedConnectionBindsWhenPresent() {
        let snapshot = NetworkSnapshot(interfaces: [wifi()], primaryName: "en0")

        XCTAssertEqual(
            NetworkBinding.named("en0").resolve(in: snapshot),
            .bound(device: "en0", carriesIPv6: false)
        )
    }

    func testNamedConnectionThatVanishedStopsEverything() {
        let snapshot = NetworkSnapshot(interfaces: [wifi()], primaryName: "en0")
        let outcome = NetworkBinding.named("utun9").resolve(in: snapshot)

        XCTAssertTrue(outcome.blocksTransfers)
        XCTAssertTrue(outcome.explanation.contains("utun9"))
    }

    func testNamedConnectionWithNoAddressStopsEverything() {
        let snapshot = NetworkSnapshot(
            interfaces: [wifi(addresses: [])], primaryName: "en0"
        )

        XCTAssertTrue(NetworkBinding.named("en0").resolve(in: snapshot).blocksTransfers)
    }

    // MARK: - IPv6

    func testIPv6IsReportedFromTheAddressesActuallyPresent() {
        let dual = tunnel(addresses: ["10.2.0.3", "2001:db8::1"])
        let snapshot = NetworkSnapshot(interfaces: [dual], primaryName: "utun6")

        XCTAssertTrue(dual.hasIPv6)
        XCTAssertEqual(
            NetworkBinding.activeVPN.resolve(in: snapshot),
            .bound(device: "utun6", carriesIPv6: true)
        )
    }

    /// An IPv4-only tunnel is the case worth saying out loud: IPv6 traffic would
    /// otherwise route around it entirely.
    func testIPv4OnlyTunnelSaysSoInItsExplanation() {
        let snapshot = NetworkSnapshot(interfaces: [tunnel()], primaryName: "utun6")
        let outcome = NetworkBinding.activeVPN.resolve(in: snapshot)

        XCTAssertTrue(
            outcome.explanation.contains("no IPv6"),
            "Expected the IPv4-only case to be stated: \(outcome.explanation)"
        )
    }

    // MARK: - "Stopped" is not "unrestricted"

    /// Both have no device to bind to, and they mean opposite things. Anything
    /// that collapses them into an optional device name gets this wrong and
    /// transfers over the real connection when it should be transferring over
    /// nothing.
    func testStoppedAndUnrestrictedAreNotInterchangeable() {
        let stopped = BindingOutcome.unavailable(reason: "gone")
        let open = BindingOutcome.unrestricted

        XCTAssertNil(stopped.device)
        XCTAssertNil(open.device)
        XCTAssertTrue(stopped.blocksTransfers)
        XCTAssertFalse(open.blocksTransfers)
        XCTAssertNotEqual(stopped, open)
    }

    // MARK: - Interface classification

    func testTunnelNamesAreRecognised() {
        for name in ["utun0", "utun12", "ipsec0", "ppp0", "wg0", "tun3"] {
            XCTAssertEqual(
                NetworkInterface(name: name, addresses: ["10.0.0.2"]).kind,
                .tunnel,
                "\(name) should read as a tunnel"
            )
        }
    }

    func testOrdinaryInterfacesAreNotTunnels() {
        for name in ["en0", "en1", "bridge0"] {
            XCTAssertEqual(
                NetworkInterface(name: name, addresses: ["192.168.1.5"]).kind,
                .ordinary,
                "\(name) should not read as a tunnel"
            )
        }
    }

    /// A tunnel with a name nothing recognises is still a tunnel, because the
    /// point-to-point flag says so.
    func testPointToPointInterfaceIsATunnelWhateverItIsCalled() {
        let odd = NetworkInterface(
            name: "vpnthing0", addresses: ["10.8.0.2"], isPointToPoint: true
        )
        XCTAssertEqual(odd.kind, .tunnel)
    }

    func testLoopbackIsNeverBindable() {
        let loopback = NetworkInterface(
            name: "lo0", addresses: ["127.0.0.1"], isLoopback: true
        )
        XCTAssertEqual(loopback.kind, .loopback)
        XCTAssertFalse(loopback.isBindable)
    }

    func testLabelKeepsTheDeviceNameVisible() {
        XCTAssertEqual(wifi().label, "Wi-Fi (en0)")
        XCTAssertEqual(tunnel().label, "utun6")
    }

    // MARK: - Persistence

    func testEveryChoiceSurvivesARoundTrip() {
        let choices: [NetworkBinding] = [.anyInterface, .activeVPN, .named("utun6"), .named("en0")]
        for choice in choices {
            XCTAssertEqual(
                NetworkBinding(storedValue: choice.storedValue),
                choice,
                "\(choice) did not survive being stored"
            )
        }
    }

    func testUnknownStoredValueFallsBackToNoRestriction() {
        for stored in ["", "nonsense", "if:"] {
            XCTAssertEqual(NetworkBinding(storedValue: stored), .anyInterface)
        }
    }

    /// An interface can't be called "vpn" on macOS, but the stored form should
    /// not depend on that being true — the prefix is what disambiguates.
    func testAnInterfaceNamedLikeTheReservedWordStillRoundTrips() {
        let awkward = NetworkBinding.named("vpn")
        XCTAssertEqual(NetworkBinding(storedValue: awkward.storedValue), awkward)
    }

    // MARK: - Side effects

    func testNoRestrictionChangesNothingElse() {
        let effects = BindingSideEffects.forBinding(.anyInterface)

        XCTAssertFalse(effects.disablesPortMapping)
        XCTAssertFalse(effects.disablesLocalDiscovery)
        XCTAssertTrue(effects.reasons.isEmpty)
    }

    func testConfiningTurnsOffTheTwoExposuresThatLeakAroundIt() {
        for binding in [NetworkBinding.activeVPN, .named("utun6")] {
            let effects = BindingSideEffects.forBinding(binding)

            XCTAssertTrue(effects.disablesPortMapping)
            XCTAssertTrue(effects.disablesLocalDiscovery)
            // Automation explains itself: one reason per thing switched off.
            XCTAssertEqual(effects.reasons.count, 2)
            XCTAssertFalse(effects.reasons.contains { $0.isEmpty })
        }
    }

    // MARK: - Reading back what the engine did

    func testListenStateCollectsAddressesFromSuccesses() {
        var state = ListenState.unknown
        // TCP and UDP on the same address both report; one address either way.
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))

        XCTAssertTrue(state.isListening)
        XCTAssertEqual(state.addresses, ["10.2.0.3"])
        XCTAssertNil(state.lastFailure)
    }

    /// A dropped tunnel has to *remove* its address. Leaving it behind is how a
    /// screen ends up claiming a connection that is long gone.
    func testListenStateForgetsAnAddressThatFailed() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        state.apply(
            ListenReport(
                address: "10.2.0.3", port: 6881, device: "utun6",
                succeeded: false, message: "device not found"
            )
        )

        XCTAssertFalse(state.isListening)
        XCTAssertTrue(state.addresses.isEmpty)
        XCTAssertEqual(state.lastFailure, "device not found")
    }

    func testListenStateAlwaysHasSomethingToSayAboutAFailure() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: false))

        XCTAssertNotNil(state.lastFailure)
        XCTAssertFalse(state.lastFailure!.isEmpty)
    }

    func testConfirmationRequiresEverySocketToBeOnTheBoundDevice() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))

        XCTAssertEqual(
            state.confirms(device: "utun6", addresses: ["10.2.0.3"]), true
        )
    }

    /// The leak this feature is meant to detect: sockets on the real connection
    /// as well as the tunnel. Every comparable client has shipped this bug.
    func testConfirmationFailsWhenAnythingIsListeningElsewhere() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        state.apply(ListenReport(address: "192.168.1.20", port: 6881, succeeded: true))

        XCTAssertEqual(
            state.confirms(device: "utun6", addresses: ["10.2.0.3"]), false
        )
    }

    func testConfirmationIsUnknownRatherThanTrueWithNothingToCompareAgainst() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))

        XCTAssertNil(state.confirms(device: "utun6", addresses: []))
    }

    /// Silence is not a leak. This used to answer `false`, which read on screen
    /// as "your traffic is going somewhere else" during the ordinary gap
    /// between choosing a connection and the engine opening a socket on it.
    func testNothingReportedYetIsUnknownRatherThanALeak() {
        XCTAssertNil(
            ListenState.unknown.confirms(device: "utun6", addresses: ["10.2.0.3"])
        )
    }

    /// A reported failure *is* a real no, and has to stay distinguishable from
    /// the silence above — otherwise the fix for one hides the other.
    func testAFailureToListenIsNotConfirmation() {
        var state = ListenState.unknown
        state.apply(
            ListenReport(
                address: "10.2.0.3", port: 6881, device: "utun6",
                succeeded: false, message: "Can't assign requested address"
            )
        )

        XCTAssertEqual(state.confirms(device: "utun6", addresses: ["10.2.0.3"]), false)
    }

    /// A socket that goes away leaves the failure behind, so a dropped tunnel
    /// stays a definite no rather than relaxing into "can't tell".
    func testLosingTheOnlySocketIsNotConfirmation() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        XCTAssertEqual(state.confirms(device: "utun6", addresses: ["10.2.0.3"]), true)

        state.apply(
            ListenReport(
                address: "10.2.0.3", port: 6881, device: "utun6",
                succeeded: false, message: "Network is down"
            )
        )
        XCTAssertEqual(state.confirms(device: "utun6", addresses: ["10.2.0.3"]), false)
    }

    // MARK: - Scoped addresses
    //
    // Not hypothetical. A real bind against a real interface reports its IPv6
    // link-local address as `fe80::…%en0`, and the interface list deliberately
    // leaves link-local out — so an address-only comparison called every
    // successful binding a leak.

    func testAScopedAddressConfirmsTheDeviceItNames() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.1.118.202", port: 6881, succeeded: true))
        state.apply(
            ListenReport(address: "fe80::40e:88b3:c2e4:bb34%en0", port: 6881, succeeded: true)
        )

        XCTAssertEqual(
            state.confirms(device: "en0", addresses: ["10.1.118.202"]), true,
            "a link-local address scoped to the bound device is not a leak"
        )
    }

    func testAScopedAddressOnAnotherDeviceIsALeak() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "10.2.0.3", port: 6881, succeeded: true))
        state.apply(ListenReport(address: "fe80::1%en0", port: 6881, succeeded: true))

        XCTAssertEqual(
            state.confirms(device: "utun6", addresses: ["10.2.0.3"]), false,
            "listening on en0's link-local while bound to utun6 is exactly the leak this catches"
        )
    }

    /// All scoped and all on the right device needs no address list at all.
    func testOnlyScopedAddressesConfirmWithoutAnAddressList() {
        var state = ListenState.unknown
        state.apply(ListenReport(address: "fe80::1%utun6", port: 6881, succeeded: true))

        XCTAssertEqual(state.confirms(device: "utun6", addresses: []), true)
    }
}
