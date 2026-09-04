import SwiftUI
import AppKit
import CurrentCore

// MARK: - Appearance

/// Light, dark, or follow the Mac.
///
/// The three options are previews, not radio buttons. A word can't tell you what
/// "Dark" will look like, and this interface was designed dark-first, so seeing
/// the two side by side is the whole decision. Each tile is a miniature of the
/// real window — chrome, sidebar, a row, the accent — drawn from the same tokens
/// the app itself uses, so it can't drift out of date.
struct AppearancePane: View {
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: Space.l) {
                Text("THEME")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)

                HStack(spacing: Space.l) {
                    ForEach(AppearanceMode.allCases) { mode in
                        tile(mode)
                    }
                }

                Text(settings.appearance.detail)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: settings.appearance)
            }
        }
    }

    private func tile(_ mode: AppearanceMode) -> some View {
        let isSelected = settings.appearance == mode

        return Button {
            // Not animated. Switching appearance re-resolves every colour in
            // the app at once, and easing that produces a muddy half-second
            // where nothing is either theme. An instant swap reads as a setting
            // taking effect.
            settings.appearance = mode
        } label: {
            VStack(spacing: Space.m) {
                ThemePreview(mode: mode)
                    .frame(height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .strokeBorder(Theme.stroke, lineWidth: Size.hairline)
                    )

                HStack(spacing: Space.s) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : mode.symbol)
                        .font(.system(size: Size.iconSmall, weight: .medium))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                        .contentTransition(.symbolEffect(.replace.offUp))
                    Text(mode.title)
                        .typeStyle(Typo.label)
                        .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                }
            }
            .padding(Space.m)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .fill(isSelected ? Theme.accentSoft : Theme.fillSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent.opacity(0.4) : Theme.stroke, lineWidth: Size.hairline)
            )
            .contentShape(Rectangle())
        }
        .pressable()
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityLabel("\(mode.title). \(mode.detail)")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

/// A miniature of the app window in a given theme.
///
/// Hard-coded colours, unavoidably: the point is to show a theme that *isn't*
/// currently active, and a dynamic token always resolves to the one that is. The
/// values are copied from `Theme` and only need revisiting if the surface greys
/// there change. `System` is drawn as both halves at once, split down the
/// middle, which says "whichever your Mac is" better than any label.
private struct ThemePreview: View {
    let mode: AppearanceMode

    var body: some View {
        switch mode {
        case .light: face(dark: false)
        case .dark: face(dark: true)
        case .system:
            HStack(spacing: 0) {
                face(dark: false)
                face(dark: true)
            }
        }
    }

    private func face(dark: Bool) -> some View {
        let chrome = dark ? Color(red: 0.071, green: 0.071, blue: 0.078) : Color(red: 0.957, green: 0.957, blue: 0.965)
        let canvas = dark ? Color(red: 0.094, green: 0.094, blue: 0.106) : .white
        let fill = dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
        let text = dark ? Color.white.opacity(0.55) : Color.black.opacity(0.45)
        let mark = dark ? Color(red: 0.247, green: 0.663, blue: 1.0) : Color(red: 0.078, green: 0.478, blue: 0.910)

        return VStack(spacing: 0) {
            // Title bar, with three dots where the window buttons live.
            HStack(spacing: 2.5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(text.opacity(0.5)).frame(width: 3.5, height: 3.5)
                }
                Spacer()
            }
            .padding(.horizontal, 5)
            .frame(height: 12)
            .background(chrome)

            HStack(spacing: 0) {
                // Sidebar, with one selected row.
                VStack(alignment: .leading, spacing: 3) {
                    RoundedRectangle(cornerRadius: 1.5).fill(fill).frame(width: 18, height: 4)
                    RoundedRectangle(cornerRadius: 1.5).fill(mark.opacity(0.8)).frame(width: 22, height: 4)
                    RoundedRectangle(cornerRadius: 1.5).fill(fill).frame(width: 16, height: 4)
                    Spacer()
                }
                .padding(5)
                .frame(width: 34)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(chrome)

                // Content, with two rows and a progress bar on the first.
                VStack(alignment: .leading, spacing: 4) {
                    row(fill: fill, text: text, mark: mark, active: true)
                    row(fill: fill, text: text, mark: mark, active: false)
                    Spacer()
                }
                .padding(5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(canvas)
            }
        }
    }

    private func row(fill: Color, text: Color, mark: Color, active: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            RoundedRectangle(cornerRadius: 1).fill(text.opacity(0.7)).frame(width: active ? 30 : 22, height: 3)
            ZStack(alignment: .leading) {
                Capsule().fill(fill).frame(height: 2)
                Capsule().fill(active ? mark : text.opacity(0.3)).frame(width: active ? 20 : 8, height: 2)
            }
        }
        .padding(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(active ? fill : .clear)
        )
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsGroup(title: "Downloads", footer: askFooter) {
                SettingRow(
                    title: "Save to",
                    detail: settings.downloadsFolder.path
                ) {
                    Button("Choose…") { chooseFolder() }
                        .currentButton(.secondary)
                }
                Hairline()
                ToggleRow(
                    title: "Ask where to save each download",
                    isOn: $settings.asksForDownloadLocation
                )
            }

            SettingsGroup(
                title: "Magnet links",
                footer: "You can change this back at any time in System Settings under Default Applications."
            ) {
                SettingRow(
                    title: "Open magnet links with Current",
                    detail: "Clicking a magnet link anywhere on your Mac hands it to this app."
                ) {
                    Button("Make Default") {
                        NSWorkspace.shared.setDefaultApplication(
                            at: Bundle.main.bundleURL,
                            toOpenURLsWithScheme: "magnet"
                        ) { _ in }
                    }
                    .currentButton(.secondary)
                }
            }
        }
    }

    /// Says what the switch above actually does in each position, because "ask
    /// where to save" reads the same whether it's on or off until you know
    /// which folder it falls back to.
    private var askFooter: String {
        settings.asksForDownloadLocation
            ? "Every download offers a folder before it starts, beginning with the one above. Ticking \"Remember this location\" there turns this off."
            : "Downloads go straight to the folder above without asking."
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = settings.downloadsFolder
        if panel.runModal() == .OK, let url = panel.url {
            settings.downloadsFolder = url
        }
    }
}

// MARK: - Bandwidth

/// A speed limit, off when zero.
///
/// Torrent clients conventionally talk in KB/s and people think in those units,
/// so the stored bytes-per-second value is only ever shown divided down. The
/// field slides in under the switch rather than being always present and
/// greyed — a disabled field is something to wonder about, an absent one isn't.
private struct RateRow: View {
    let label: String
    let detail: String?
    @Binding var bytesPerSecond: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isLimited: Binding<Bool> {
        Binding(
            get: { bytesPerSecond > 0 },
            // Switching a limit on at zero would silently stop all traffic, so
            // it picks a sane starting point instead.
            set: { bytesPerSecond = $0 ? max(bytesPerSecond, 1_000_000) : 0 }
        )
    }

    private var kilobytes: Binding<Int> {
        Binding(
            get: { bytesPerSecond / 1000 },
            set: { bytesPerSecond = max(0, $0) * 1000 }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToggleRow(title: label, detail: detail, isOn: isLimited)
            if isLimited.wrappedValue {
                HStack {
                    Spacer()
                    NumberField(value: kilobytes, unit: "KB/s", range: 1...10_000_000)
                }
                .padding(.bottom, Space.m)
                .transition(
                    reduceMotion
                        ? .opacity
                        : .opacity.combined(with: .move(edge: .top))
                )
            }
        }
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isLimited.wrappedValue)
    }
}

struct BandwidthPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var app: AppEnvironment

    var body: some View {
        SettingsPane {
            SettingsGroup(title: "Normal speeds") {
                RateRow(label: "Limit download speed", detail: nil, bytesPerSecond: $settings.normalDownloadLimit)
                Hairline()
                RateRow(label: "Limit upload speed", detail: nil, bytesPerSecond: $settings.normalUploadLimit)
            }

            SettingsGroup(
                title: "Reduced speeds",
                footer: "A slower set you can switch to when you need the connection for something else. Also used automatically on battery, if that's enabled in Power."
            ) {
                RateRow(label: "Limit download speed", detail: nil, bytesPerSecond: $settings.reducedDownloadLimit)
                Hairline()
                RateRow(label: "Limit upload speed", detail: nil, bytesPerSecond: $settings.reducedUploadLimit)
                Hairline()
                ToggleRow(title: "Use reduced speeds now", isOn: $settings.isReducedSpeedForced)
            }

            // Anything the app decides on its own has to be able to say why —
            // see AGENTS.md. This is that sentence for bandwidth.
            Callout(symbol: "info.circle.fill", tint: Theme.accent) {
                Text("Right now")
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                Text(app.bandwidthExplanation)
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsGroup(
                title: "Queue",
                footer: "Anything past these waits its turn, instead of every torrent starting at once and splitting the line."
            ) {
                SettingRow(title: "Download at most") {
                    CurrentStepper(value: $settings.maxActiveDownloads, range: 1...20, unit: "at a time")
                }
                Hairline()
                SettingRow(title: "Seed at most") {
                    CurrentStepper(value: $settings.maxActiveSeeds, range: 0...50, unit: "at a time")
                }
            }

            SettingsGroup(title: "Connections") {
                SettingRow(title: "Peer connections") {
                    CurrentStepper(value: $settings.maxConnections, range: 20...1000, step: 20, unit: "peers")
                }
                Hairline()
                SettingRow(title: "Upload slots") {
                    CurrentStepper(value: $settings.maxUploadSlots, range: 1...50, unit: "slots")
                }
            }
        }
    }
}

// MARK: - Network

struct NetworkPane: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let encryptionOptions: [(value: EncryptionPolicy, title: String, detail: String)] =
        EncryptionPolicy.allCases.map { ($0, $0.title, $0.detail) }

    var body: some View {
        SettingsPane {
            SettingsGroup(
                title: "Incoming connections",
                footer: "Without a reachable port you can still download, but fewer peers can reach you and speeds suffer."
            ) {
                SettingRow(title: "Listening port") {
                    NumberField(value: $settings.listenPort, range: 1024...65535, grouped: false)
                }
                Hairline()
                ToggleRow(
                    title: "Map the port automatically",
                    detail: "Uses UPnP or NAT-PMP to ask your router to forward it.",
                    isOn: $settings.isPortMappingEnabled
                )
            }

            SettingsGroup(title: "Finding peers") {
                ToggleRow(
                    title: "Distributed hash table",
                    detail: "Finds peers without needing a tracker.",
                    isOn: $settings.isDHTEnabled
                )
                Hairline()
                ToggleRow(
                    title: "Local peer discovery",
                    detail: "Finds peers on your own network — fast, and uses no internet bandwidth.",
                    isOn: $settings.isLocalDiscoveryEnabled
                )
            }

            VStack(alignment: .leading, spacing: Space.m) {
                Text("ENCRYPTION")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                RadioGroup(selection: $settings.encryption, options: Self.encryptionOptions)
            }
        }
    }
}

// MARK: - Storage

struct StoragePane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var app: AppEnvironment
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isCleaning = false

    private var limitGB: Binding<Double> {
        Binding(
            get: { Double(settings.storageLimitBytes ?? 100_000_000_000) / 1_000_000_000 },
            set: { settings.storageLimitBytes = Int64($0) * 1_000_000_000 }
        )
    }

    var body: some View {
        SettingsPane {
            SettingsGroup(
                title: "Budget",
                footer: "When the budget runs low, Current suggests the completed downloads that are safest to remove. Always reversible — files go to the Trash."
            ) {
                ToggleRow(
                    title: "Limit torrent storage",
                    isOn: Binding(
                        get: { settings.storageLimitBytes != nil },
                        set: { settings.storageLimitBytes = $0 ? 100_000_000_000 : nil }
                    )
                )

                if settings.storageLimitBytes != nil {
                    VStack(alignment: .leading, spacing: Space.m) {
                        CurrentSlider(value: limitGB, range: 10...2000, step: 10)
                        HStack {
                            Text("\(ByteFormatting.bytes(store.usedStorageBytes)) used")
                                .foregroundStyle(Theme.textSecondary)
                            Spacer()
                            Text("\(Int(limitGB.wrappedValue)) GB budget")
                                .foregroundStyle(Theme.text)
                        }
                        .typeStyle(Typo.caption)
                        .tabularNumerics()
                        .numericTransition()
                    }
                    .padding(.bottom, Space.l)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }

            SettingsGroup(
                footer: "Automatic cleanup only removes torrents whose seeding goals are met and whose swarms are healthy. Rare torrents are always kept, and files move to the Trash — so cleanup is reversible."
            ) {
                ToggleRow(
                    title: "Clean up automatically when over budget",
                    isOn: $settings.isAutoCleanupEnabled
                )
                Hairline()
                SettingRow(
                    title: "Clean now",
                    detail: app.cleanup.plan.candidates.isEmpty
                        ? "Nothing is eligible at the moment."
                        : "\(app.cleanup.plan.candidates.count) download\(app.cleanup.plan.candidates.count == 1 ? "" : "s") eligible."
                ) {
                    Button {
                        isCleaning = true
                        Task {
                            await app.cleanEligibleNow()
                            isCleaning = false
                        }
                    } label: {
                        if isCleaning {
                            Spinner(size: 12, tint: Theme.text)
                        } else {
                            Text("Clean Now")
                        }
                    }
                    .currentButton(.secondary)
                    .disabled(isCleaning || app.cleanup.plan.candidates.isEmpty)
                }
            }
        }
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: settings.storageLimitBytes == nil)
    }
}

// MARK: - Seeding

struct SeedingPane: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let options: [(value: String, title: String, detail: String)] = [
        ("balanced", "Balanced", "Stops after a 1.0× share ratio and 24 hours of seeding."),
        ("helpful", "Helpful", "Balanced rules, but stays available while a torrent is rare."),
        ("temporary", "Temporary", "Seeds to the goal, then becomes ready for cleanup."),
        ("archive", "Archive", "Keeps seeding indefinitely."),
    ]

    var body: some View {
        SettingsPane {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("NEW DOWNLOADS USE")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                RadioGroup(
                    selection: Binding(
                        get: { Self.key(settings.defaultSeedPolicy) },
                        set: { settings.defaultSeedPolicy = Self.policy(for: $0) }
                    ),
                    options: Self.options
                )
                Text("Each torrent can override this from its Rules tab in the details panel.")
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private static func key(_ policy: SeedPolicy) -> String {
        switch policy {
        case .balanced: return "balanced"
        case .helpful: return "helpful"
        case .archive: return "archive"
        case .temporary: return "temporary"
        case .custom: return "custom"
        }
    }

    private static func policy(for key: String) -> SeedPolicy {
        switch key {
        case "helpful": return .helpful
        case "archive": return .archive
        case "temporary": return .temporary
        default: return .balanced
        }
    }
}

// MARK: - Power

struct PowerPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsGroup(
                title: "On battery",
                footer: "Seeding continues on battery regardless — it's light work. Only downloads pause or slow down."
            ) {
                ToggleRow(title: "Pause downloads", isOn: $settings.pauseDownloadsOnBattery)
                Hairline()
                ToggleRow(
                    title: "Keep downloading, but slower",
                    detail: "Uses the reduced speeds from the Bandwidth pane.",
                    isOn: $settings.limitSpeedsOnBattery
                )
            }

            SettingsGroup(title: "Sleep") {
                // Not conditional on anything. This used to be disabled unless
                // one of the battery switches above was on, which made no
                // sense in either direction — keeping the Mac awake for a
                // download is exactly as useful on mains power, and more so.
                ToggleRow(
                    title: "Prevent sleep while downloading",
                    detail: "Only while something is actually transferring. Closing the lid still sleeps.",
                    isOn: $settings.preventSleepWhileDownloading
                )
            }
        }
    }
}

// MARK: - Notifications

struct NotificationsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        SettingsPane {
            SettingsGroup(
                title: "Notify me when",
                footer: "Current never notifies about routine events — no “peer connected”, no “ratio increased”."
            ) {
                ToggleRow(title: "A download completes", isOn: $settings.notifyOnCompletion)
                Hairline()
                ToggleRow(title: "A download fails", isOn: $settings.notifyOnFailure)
                Hairline()
                ToggleRow(title: "Storage budget needs attention", isOn: $settings.notifyOnBudgetPressure)
            }
        }
    }
}
