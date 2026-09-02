import SwiftUI
import CurrentCore

enum SettingsTab: Hashable {
    case general
    case bandwidth
    case network
    case storage
    case seeding
    case power
    case notifications
}

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Binding var tab: SettingsTab

    var body: some View {
        TabView(selection: $tab) {
            GeneralPane().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            BandwidthPane().tabItem { Label("Bandwidth", systemImage: "speedometer") }.tag(SettingsTab.bandwidth)
            NetworkPane().tabItem { Label("Network", systemImage: "network") }.tag(SettingsTab.network)
            StoragePane().tabItem { Label("Storage", systemImage: "internaldrive") }.tag(SettingsTab.storage)
            SeedingPane().tabItem { Label("Seeding", systemImage: "seedling") }.tag(SettingsTab.seeding)
            PowerPane().tabItem { Label("Power", systemImage: "battery.75") }.tag(SettingsTab.power)
            NotificationsPane().tabItem { Label("Notifications", systemImage: "bell") }.tag(SettingsTab.notifications)
        }
        .frame(width: 480)
        .padding(20)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            LabeledContent("Download to") {
                HStack {
                    Text(settings.downloadsFolder.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…") { chooseFolder() }
                }
            }

            Divider()

            Button("Make Current the default for magnet links") {
                NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL,
                    toOpenURLsWithScheme: "magnet"
                ) { error in
                    _ = error
                }
            }

            Text("Current stays completely local. No accounts, no analytics, no tracking — your torrent history never leaves this Mac.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
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

/// A speed limit, off when zero. Torrent clients conventionally talk in KB/s
/// and people think in those units, so the stored bytes/second value is only
/// ever shown divided down.
private struct RateRow: View {
    let label: String
    @Binding var bytesPerSecond: Int

    private var isLimited: Binding<Bool> {
        Binding(
            get: { bytesPerSecond > 0 },
            // Turning a limit on with a value of zero would silently stop all
            // traffic, so switching on picks a sane starting point.
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
        VStack(alignment: .leading, spacing: 6) {
            Toggle(label, isOn: isLimited)
            if isLimited.wrappedValue {
                HStack(spacing: 6) {
                    TextField(
                        "",
                        value: kilobytes,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 90)
                    .tabularNumerics()
                    Text("KB/s")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.leading, 20)
            }
        }
    }
}

private struct BandwidthPane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var app: AppEnvironment

    var body: some View {
        Form {
            Section("Normal speeds") {
                RateRow(label: "Limit download speed", bytesPerSecond: $settings.normalDownloadLimit)
                RateRow(label: "Limit upload speed", bytesPerSecond: $settings.normalUploadLimit)
            }

            Section("Reduced speeds") {
                Text("A slower set you can switch to when you need the connection for something else.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                RateRow(label: "Limit download speed", bytesPerSecond: $settings.reducedDownloadLimit)
                RateRow(label: "Limit upload speed", bytesPerSecond: $settings.reducedUploadLimit)
                Toggle("Use reduced speeds now", isOn: $settings.isReducedSpeedForced)
                Text("Also switched on automatically while on battery, if that is enabled in Power.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Right now") {
                // Anything the app decides on its own has to be able to say
                // why — see AGENTS.md.
                Label(app.bandwidthExplanation, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Queue") {
                Stepper(
                    "Download at most \(settings.maxActiveDownloads) at a time",
                    value: $settings.maxActiveDownloads, in: 1...20
                )
                Stepper(
                    "Seed at most \(settings.maxActiveSeeds) at a time",
                    value: $settings.maxActiveSeeds, in: 0...50
                )
                Text("Anything past these waits its turn instead of every torrent starting at once and splitting the line.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connections") {
                Stepper(
                    "Up to \(settings.maxConnections) peer connections",
                    value: $settings.maxConnections, in: 20...1000, step: 20
                )
                Stepper(
                    "Up to \(settings.maxUploadSlots) upload slots",
                    value: $settings.maxUploadSlots, in: 1...50
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Network

private struct NetworkPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Section("Incoming connections") {
                HStack(spacing: 6) {
                    Text("Listening port")
                    Spacer()
                    TextField(
                        "",
                        value: $settings.listenPort,
                        format: .number.precision(.fractionLength(0))
                    )
                    .frame(width: 90)
                    .tabularNumerics()
                }
                Toggle("Map the port automatically (UPnP / NAT-PMP)", isOn: $settings.isPortMappingEnabled)
                Text("Without a reachable port you can still download, but fewer peers can reach you and speeds suffer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Finding peers") {
                Toggle("Distributed hash table (DHT)", isOn: $settings.isDHTEnabled)
                Toggle("Local peer discovery", isOn: $settings.isLocalDiscoveryEnabled)
                Text("DHT finds peers without a tracker. Local discovery finds them on your own network, which is fast and uses no internet bandwidth.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Encryption") {
                Picker("Peer connections", selection: $settings.encryption) {
                    ForEach(EncryptionPolicy.allCases, id: \.self) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(settings.encryption.detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Storage

private struct StoragePane: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var app: AppEnvironment

    @State private var isCleaning = false

    private var limitGB: Binding<Double> {
        Binding(
            get: { Double(settings.storageLimitBytes ?? 100_000_000_000) / 1_000_000_000 },
            set: { settings.storageLimitBytes = Int64($0) * 1_000_000_000 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Limit torrent storage", isOn: Binding(
                    get: { settings.storageLimitBytes != nil },
                    set: { on in
                        settings.storageLimitBytes = on ? 100_000_000_000 : nil
                    }
                ))

                if settings.storageLimitBytes != nil {
                    VStack(alignment: .leading) {
                        Slider(value: limitGB, in: 10...2_000, step: 10)
                        Text("\(ByteFormatting.bytes(store.usedStorageBytes)) used of \(Int(limitGB.wrappedValue)) GB budget")
                            .font(.caption.tabularNumerics())
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Budget")
            } footer: {
                Text("When the budget runs low, Current suggests completed downloads that are safest to remove — always reversible, files go to the Trash.")
            }

            Section {
                Toggle(
                    "Clean up automatically when over budget",
                    isOn: $settings.isAutoCleanupEnabled
                )

                HStack {
                    Spacer()
                    Button {
                        isCleaning = true
                        Task {
                            await app.cleanEligibleNow()
                            isCleaning = false
                        }
                    } label: {
                        if isCleaning {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Clean Now")
                        }
                    }
                    .disabled(isCleaning || store.usedStorageBytes == 0)
                }
            } footer: {
                Text("Automatic cleanup only removes torrents whose seeding goals are met and whose swarms are healthy. Rare torrents are always kept. Files move to the Trash, so cleanup is reversible.")
            }
        }
    }
}

// MARK: - Seeding

private struct SeedingPane: View {
    @EnvironmentObject private var settings: SettingsStore

    private static let options: [(SeedPolicy, String)] = [
        (.balanced, "Balanced — stops after a 1.0× share ratio and 24 hours of seeding."),
        (.helpful, "Helpful — Balanced rules, but stays available while a torrent is rare."),
        (.temporary, "Temporary — seeds to the goal, then becomes ready for cleanup."),
        (.archive, "Archive — keeps seeding indefinitely."),
    ]

    var body: some View {
        Form {
            Picker("New downloads use", selection: $settings.defaultSeedPolicy) {
                ForEach(Self.options, id: \.0) { policy, _ in
                    Text(policy.label).tag(policy)
                }
            }
            .pickerStyle(.radioGroup)

            Text(settings.defaultSeedPolicy.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Each torrent can override this from its Rules tab in the inspector.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Power

private struct PowerPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("Pause downloads when on battery", isOn: $settings.pauseDownloadsOnBattery)
            Toggle("Keep downloading but slower when on battery", isOn: $settings.limitSpeedsOnBattery)
            Toggle("Prevent sleep while downloading", isOn: $settings.preventSleepWhileDownloading)
                .disabled(!settings.pauseDownloadsOnBattery && !settings.limitSpeedsOnBattery)

            Text("Seeding continues on battery regardless — it's light work. Downloads pause or slow down to protect battery life.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        Form {
            Toggle("A download completes", isOn: $settings.notifyOnCompletion)
            Toggle("A download fails", isOn: $settings.notifyOnFailure)
            Toggle("Storage budget needs attention", isOn: $settings.notifyOnBudgetPressure)

            Text("Current never notifies about routine events — no “peer connected”, no “ratio increased”.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
