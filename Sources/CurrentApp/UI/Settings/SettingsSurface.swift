import SwiftUI
import AppKit
import CurrentCore

enum SettingsTab: Hashable, CaseIterable, Identifiable {
    case general
    case appearance
    case bandwidth
    case network
    case storage
    case seeding
    case power
    case notifications

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .bandwidth: return "Bandwidth"
        case .network: return "Network"
        case .storage: return "Storage"
        case .seeding: return "Seeding"
        case .power: return "Power"
        case .notifications: return "Notifications"
        }
    }

    /// Measured, not picked by eye. Every glyph here fits `Size.iconColumn`, so
    /// the rail's icons all sit in the same 18pt slot and every label starts at
    /// the same x. Power used to be `battery.75`, which renders 21pt wide and
    /// 11pt tall — the widest and the flattest symbol in the app — so it hung
    /// outside the column on both sides and made the whole rail look ragged.
    /// `bolt.batteryblock` is 17×13 and still says "battery".
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .bandwidth: return "speedometer"
        case .network: return "network"
        case .storage: return "internaldrive"
        case .seeding: return "arrow.up.arrow.down"
        case .power: return "bolt.batteryblock"
        case .notifications: return "bell"
        }
    }
}

/// Settings, inside the window.
///
/// The old build used SwiftUI's `Settings` scene, which meant a second window
/// wearing a system title bar, a `TabView` of system tab icons, and stock
/// `Form` rows — the densest concentration of stock-macOS in the whole app, and
/// nothing about it could be restyled. Presenting settings as one of the app's
/// own surfaces is both what Cursor does and the only way for the pane to look
/// like the app it belongs to.
///
/// ⌘, still opens it and Escape still closes it, because those are the two keys
/// people reach for without thinking.
struct SettingsSurface: View {
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.windowSize) private var windowSize

    /// The card's own width, resolved the same way `.modalSize` resolves it
    /// below — the rail needs it to know how much of it it can have.
    private var cardWidth: CGFloat {
        WindowLayout.modalSize(
            preferred: CGSize(width: SettingsChrome.width, height: SettingsChrome.height),
            container: windowSize,
            margin: Chrome.modalMargin,
            minimum: Chrome.modalMinSize
        ).width
    }

    private var railWidth: CGFloat {
        WindowLayout.settingsRailWidth(
            cardWidth: cardWidth,
            preferred: SettingsChrome.railWidth,
            minimum: SettingsChrome.railMinWidth,
            minimumPane: SettingsChrome.paneMinWidth
        )
    }

    /// Below a certain card width there isn't room for two columns, so the tabs
    /// move into the header instead — the same trade the chrome bar makes when
    /// the sidebar folds away.
    private var showsRail: Bool {
        WindowLayout.settingsShowsRail(
            cardWidth: cardWidth,
            minimumRail: SettingsChrome.railMinWidth,
            minimumPane: SettingsChrome.paneMinWidth
        )
    }

    var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture { close() }

            card
                .popTransition(reduceMotion: reduceMotion)
        }
        // Centred on the window rather than on the safe area — see
        // `ModalSurface`. This card is 540pt tall, so in a short window the
        // difference was its bottom edge being clipped.
        .ignoresSafeArea()
        .background(EscapeCatcher { close() }.frame(width: 0, height: 0))
    }

    private var card: some View {
        HStack(spacing: 0) {
            if showsRail {
                rail
                Hairline(axis: .vertical)
            }
            pane
        }
        // The window's, not the card's, decision — see `WindowLayout`. This is
        // the surface that found the bug: at a fixed 760×540 it drew over all
        // four edges of a smaller window, close button included.
        .modalSize(width: SettingsChrome.width, height: SettingsChrome.height)
        .raisedSurface(radius: Radius.xl, deep: true)
        // Clipped so the rail's own fill can run to the card's rounded corners
        // without squaring them off.
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl, style: .continuous))
    }

    // MARK: - Rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Same height box as the pane's header, so this title and the pane's
            // land on one line instead of missing each other by 3pt.
            Text("Settings")
                .typeStyle(Typo.title)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, SettingsChrome.inset)
                .frame(height: SettingsChrome.headerHeight, alignment: .leading)

            // Scrolls, because the card is no longer guaranteed to be 540pt
            // tall: in a short window the eight rows are taller than the space
            // they have, and a clipped rail is a tab you cannot reach.
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(SettingsTab.allCases) { tab in
                        railRow(tab)
                    }
                }
            }
            .scrollIndicators(.never)
            // Only as tall as the rows when there's room, so the footer stays at
            // the bottom of the card rather than being pushed there by a greedy
            // scroll view.
            .frame(maxHeight: SettingsChrome.railRowsHeight)

            Spacer(minLength: 0)

            // The privacy line lives here rather than buried in General,
            // because it is the app's actual position and worth stating
            // wherever someone is poking at settings.
            Text("No accounts, no analytics, no tracking. Everything stays on this Mac.")
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textQuaternary)
                .fixedSize(horizontal: false, vertical: true)
                // The card's margin, so the bottom-left corner has the same gap
                // as the bottom-right one.
                .padding(SettingsChrome.inset)
        }
        // Gives up width to the pane in a shrunken card, down to its own floor —
        // clamping the card alone only moved the problem into the pane.
        .frame(width: railWidth)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.chrome)
    }

    private func railRow(_ tab: SettingsTab) -> some View {
        let isSelected = app.settingsTab == tab

        return Button {
            withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
                app.settingsTab = tab
            }
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: tab.symbol)
                    .font(.system(size: Size.iconSmall, weight: .medium))
                    .frame(width: Size.iconColumn)
                    .foregroundStyle(isSelected ? Theme.text : Theme.textTertiary)
                Text(tab.title)
                    .typeStyle(Typo.label)
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                    // Truncates rather than wraps. The row is a fixed 30pt, so a
                    // label that took two lines in a narrowed rail wouldn't be
                    // shortened — it would be cut in half.
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            // With the row inset below, this lands the icon column on the
            // card's margin — level with the title above and the footer below.
            .padding(.horizontal, Space.m)
            .frame(height: Size.sidebarRow)
            .background(
                RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                    .fill(isSelected ? Theme.fillMuted : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Hover fill first, *then* the inset. The other order put the hover fill
        // behind the padded button, so it spanned the full width of the rail
        // while the selected fill was inset 8pt — hovering a row drew a wider
        // rectangle than selecting it did.
        .hoverFill(Radius.m, active: !isSelected)
        .padding(.horizontal, SettingsChrome.rowInset)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    // MARK: - Pane

    private var pane: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.m) {
                paneTitle
                Spacer(minLength: Space.m)
                Button { close() } label: {
                    Image(systemName: "xmark")
                }
                .iconButton()
                .help("Close settings")
            }
            .padding(.leading, SettingsChrome.inset)
            // Less than the leading inset by exactly the button's own slack —
            // see `SettingsChrome.headerTrailing`.
            .padding(.trailing, SettingsChrome.headerTrailing)
            // Fixed rather than measured from the tallest child, which is what
            // used to make this header 6pt taller than the rail's.
            .frame(height: SettingsChrome.headerHeight)

            Hairline()

            ScrollView {
                content
                    .padding(SettingsChrome.inset)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.raised)
    }

    /// The pane's title — and, when the rail has folded away, the only way to
    /// change tabs.
    ///
    /// A native `Menu`, which is the one place this app doesn't draw its own:
    /// see AGENTS.md. It's also the same move the chrome bar makes with the
    /// section name in the compact layout, so a narrow settings card behaves
    /// like a narrow window rather than like a different app.
    @ViewBuilder
    private var paneTitle: some View {
        if showsRail {
            Text(app.settingsTab.title)
                .typeStyle(Typo.title)
                .foregroundStyle(Theme.text)
        } else {
            Menu {
                Picker("Section", selection: $app.settingsTab) {
                    ForEach(SettingsTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.symbol).tag(tab)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: Space.s) {
                    Text(app.settingsTab.title)
                        .typeStyle(Typo.title)
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings section, currently \(app.settingsTab.title)")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch app.settingsTab {
        case .general: GeneralPane()
        case .appearance: AppearancePane()
        case .bandwidth: BandwidthPane()
        case .network: NetworkPane()
        case .storage: StoragePane()
        case .seeding: SeedingPane()
        case .power: PowerPane()
        case .notifications: NotificationsPane()
        }
    }

    /// No `withAnimation` here on purpose. The presenting overlay in `AppShell`
    /// carries `Motion.pop(presenting:)`, which has to own both directions —
    /// animating from this end as well would fight it, and would only cover the
    /// closes that happen to go through this method.
    private func close() {
        app.isSettingsVisible = false
    }
}

// MARK: - Row furniture

/// A settings row: name and explanation on the left, control on the right.
///
/// This shape replaces `LabeledContent` and `Form`, and it is the reason the
/// panes read as sentences rather than as a database form. Every setting in this
/// app can explain itself — that is the same principle the Rules tab follows —
/// and putting the explanation *under the label* rather than in a separate
/// paragraph is what makes room for it.
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Space.l)
            control()
                // Aligned to the label's cap height rather than the top of the
                // text box, or a 28pt control sits a couple of points high next
                // to a 12.5pt label.
                .padding(.top, 1)
        }
        .padding(.vertical, Space.m)
    }
}

/// A row whose control *is* a switch, so the whole row is the target.
struct ToggleRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .typeStyle(Typo.label)
                if let detail {
                    Text(detail)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .currentSwitch()
        .padding(.vertical, Space.m)
    }
}

/// A titled group of rows, with hairlines between them.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                Text(title.uppercased())
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .insetCard(radius: Radius.l)
            if let footer {
                Text(footer)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Space.hair)
            }
        }
    }
}

/// The stack every pane sits in.
struct SettingsPane<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl, content: content)
    }
}
