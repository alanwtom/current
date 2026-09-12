import SwiftUI
import AppKit
import CurrentCore

/// The app's title bar, drawn by the app.
///
/// This replaces the system title bar *and* the unified toolbar the old build
/// used. Between them they were responsible for most of the stock-Mac feeling:
/// a window title nobody needs, a toolbar with its own hairline and its own
/// idea of how tall it should be, and a search field squeezed into a slot that
/// pushed everything else into an overflow menu the moment the window got
/// narrow.
///
/// The three window buttons still belong to AppKit — they are floating on top of
/// this view, in the space `Chrome.trafficLightInset` leaves for them. Drawing
/// our own would mean reimplementing their hover behaviour, their disabled
/// states, and their full-screen alternates, all to end up somewhere slightly
/// worse.
///
/// Its height is fixed rather than measured. See `WindowChrome` for why there is
/// no `NSToolbar` growing the title bar, and `Chrome.barControlHeight` for how
/// the app's controls end up on the same line as the window buttons.
struct ChromeBar: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Binding var isSidebarVisible: Bool
    @Binding var isInspectorVisible: Bool
    let searchFocus: FocusState<Bool>.Binding

    @Environment(\.isCompactLayout) private var isCompact
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Space.m) {
            // The window buttons live here. Nothing else may.
            Spacer().frame(width: Chrome.trafficLightInset)

            sidebarToggle
            sectionLabel

            Spacer(minLength: Space.l)

            // The combined rates are the first thing to go when the window gets
            // narrow. They are a nicety; the add button is not, and at 500pt the
            // two together pushed it off the right edge entirely.
            // Ahead of the rates, and it survives the compact layout the rates
            // don't. "Which connection is carrying this" outranks "here is how
            // fast it's going", and this is the only place the window says it at
            // all — the setting behind it is four clicks deep in a pane you last
            // opened a month ago.
            BindingMarker(network: app.network) {
                app.settingsTab = .network
                app.isSettingsVisible = true
            }

            if !isCompact {
                ActivityReadout()
            }

            SearchField(text: $store.searchText, width: isCompact ? 110 : 190)
                .focused(searchFocus)

            addMenu

            if !isCompact {
                Button {
                    app.isCommandPaletteVisible.toggle()
                } label: {
                    Image(systemName: "command")
                }
                .iconButton()
                .help("Command palette ⌘K")

                Button {
                    withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                        isInspectorVisible.toggle()
                    }
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .iconButton(isActive: isInspectorVisible)
                .help("Toggle details")
            }
        }
        .padding(.horizontal, Space.l)
        // Simply centred. The window buttons are moved to this same centre line
        // by `WindowChrome`, so the whole row balances in the bar instead of
        // hugging its top edge.
        .frame(maxWidth: .infinity)
        .frame(height: Chrome.barHeight)
        .background {
            // The drag region sits behind the controls, so a button keeps its
            // own clicks while the empty space acts like a real title bar —
            // drag to move, double-click to zoom.
            WindowDragRegion()
        }
        // No line underneath. The bar, the sidebar, the inspector and the gutter
        // around the library are all one continuous surface now, and the content
        // is set into it — so a rule here would be the only drawn seam left in
        // the window, marking a boundary the inset pane already makes obvious.
        .background(Theme.chrome)
    }

    // MARK: - Pieces

    private var sidebarToggle: some View {
        Button {
            withAnimation(Motion.spring(reduceMotion: reduceMotion)) {
                isSidebarVisible.toggle()
            }
        } label: {
            Image(systemName: "sidebar.leading")
        }
        .iconButton(isActive: isSidebarVisible)
        .help(isSidebarVisible ? "Hide sections ⌘0" : "Show sections ⌘0")
    }

    /// What the window title used to say, except useful.
    ///
    /// In the compact layout it doubles as the section picker, because that is
    /// where the sidebar has gone. Turning the label itself into the control
    /// avoids a second button competing for space in a bar that has already run
    /// out of it.
    @ViewBuilder
    private var sectionLabel: some View {
        if isCompact || !isSidebarVisible {
            Menu {
                Picker("Section", selection: $store.activeSection) {
                    Section("Library") {
                        ForEach(SidebarSection.library, id: \.self) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                    Section("Smart") {
                        ForEach(SidebarSection.smart, id: \.self) { section in
                            Label(section.title, systemImage: section.symbol).tag(section)
                        }
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: Space.m) {
                    Text(store.activeSection.title)
                        .typeStyle(Typo.label)
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .padding(.horizontal, Space.m)
                .frame(height: Size.iconButton)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .hoverFill(Radius.s)
            .accessibilityLabel("Section, currently \(store.activeSection.title)")
        } else {
            // With the sidebar open the section is already named over there, so
            // this is a label and nothing more.
            Text(store.activeSection.title)
                .typeStyle(Typo.label)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Add Magnet Link…") { app.beginAddMagnet() }
            Button("Open Torrent File…") { app.pickTorrentFile() }
        } label: {
            Image(systemName: "plus")
        } primaryAction: {
            // Clicking the button adds a magnet; holding it open offers the
            // file picker. The common case shouldn't cost a menu.
            app.beginAddMagnet()
        }
        .menuStyle(.button)
        .buttonStyle(CurrentButton(role: .primary, scale: .regular))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add torrent ⌘N")
    }
}

/// The state of the connection every transfer is confined to, in the title bar.
///
/// Shown whenever a binding is set, not only when it has failed. This used to
/// be a "Transfers stopped" chip that appeared on the one bad outcome, so the
/// *good* outcome — the VPN carrying everything, which is the whole point of
/// turning this on — was invisible, and the only way to check it was to open
/// the pane. A status light says both, and a light you see every day is one you
/// can read at a glance on the day it changes colour.
///
/// **It reads the engine, not the setting.** `isBindingConfirmed` is nil until
/// the engine reports the sockets it really opened, and that state is amber,
/// never green. Drawing a chosen binding as a working one is the exact failure
/// this feature exists to make visible.
///
/// **Its size never changes**, which is why the word is gone. A title-bar item
/// that grows with its text re-measures the window, and this one changes state
/// while somebody is looking at it — see the layout-churn rules in AGENTS.md.
/// The glyph differs per state as well as the tint, so it doesn't rest on
/// colour alone, and the sentence moves to the tooltip.
private struct BindingMarker: View {

    @ObservedObject var network: NetworkMonitor
    let openSettings: () -> Void

    var body: some View {
        if let state {
            Button(action: openSettings) {
                Image(systemName: state.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(state.tint)
                    .frame(width: Size.controlS, height: Size.controlS)
                    .background(
                        Capsule(style: .continuous).fill(state.tint.opacity(0.13))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(state.tint.opacity(0.22), lineWidth: Size.hairline)
                    )
            }
            .buttonStyle(.plain)
            .pressable()
            .help(state.explanation)
            .accessibilityLabel(state.explanation)
            .transition(.opacity)
        }
    }

    /// Nil when nothing is confined: there is no status to report, so the title
    /// bar says nothing rather than carrying a permanent "off" light.
    private var state: State? {
        switch network.outcome {
        case .unrestricted:
            return nil
        case .unavailable(let reason):
            // Amber rather than red — nothing broke and nothing was lost. The
            // connection you insisted on isn't there, which is something you
            // can go and fix.
            return State(
                symbol: "network.slash",
                tint: Theme.warning,
                explanation: "Transfers are stopped. \(reason) Open Network settings."
            )
        case .bound(let device, _):
            switch network.isBindingConfirmed {
            case .some(true):
                return State(
                    symbol: "checkmark.shield.fill",
                    tint: Theme.complete,
                    explanation: "Transfers are confined to \(device). Open Network settings."
                )
            case .some(false):
                // A broken shield, not a warning badge. The exclamation mark
                // read as "your VPN is faulty", which is a claim about the
                // tunnel this app is in no position to make. What it actually
                // knows is narrower: the protection isn't in place.
                return State(
                    symbol: "shield.slash.fill",
                    tint: Theme.failure,
                    explanation: "Transfers are not going over \(device). Open Network settings."
                )
            case .none:
                return State(
                    symbol: "shield.lefthalf.filled",
                    tint: Theme.warning,
                    explanation: "Waiting for \(device) to confirm. Open Network settings."
                )
            }
        }
    }

    private struct State {
        let symbol: String
        let tint: Color
        let explanation: String
    }
}
