import SwiftUI
import CurrentCore

struct Sidebar: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: SettingsStore

    var body: some View {
        List(selection: $store.activeSection) {
            Section("Library") {
                ForEach(SidebarSection.library, id: \.self) { section in
                    SidebarRow(
                        section: section,
                        count: store.count(for: section)
                    )
                    .tag(section)
                }
            }

            Section("Smart") {
                ForEach(SidebarSection.smart, id: \.self) { section in
                    SidebarRow(
                        section: section,
                        count: store.count(for: section),
                        emphasized: section == .attention || section == .readyToClean
                    )
                    .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StorageMeter()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
    }
}

private struct SidebarRow: View {
    @EnvironmentObject private var app: AppEnvironment
    let section: SidebarSection
    let count: Int
    var emphasized = false

    /// Ready-to-clean is driven by the cleanup plan, not raw snapshots.
    private var displayCount: Int? {
        if section == .readyToClean {
            let n = app.cleanup.plan.candidates.count
            return n > 0 ? n : nil
        }
        return count > 0 ? count : nil
    }

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
                .foregroundStyle(emphasized && (displayCount ?? 0) > 0 ? Color.accentColor : .primary)
            Spacer()
            if let displayCount {
                Text("\(displayCount)")
                    .font(.caption.tabularNumerics().weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Storage meter

/// Quiet budget indicator pinned to the sidebar bottom. Appears only once a
/// budget exists; tapping opens the storage pane of Settings.
struct StorageMeter: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingPopover = false

    private var usedBytes: Int64 { store.usedStorageBytes }

    var body: some View {
        Group {
            if let limit = settings.storageLimitBytes {
                meter(limit: limit)
            } else if usedBytes > 0 {
                Button {
                    app.openSettings(tab: .storage)
                } label: {
                    Label(ByteFormatting.bytes(usedBytes), systemImage: "internaldrive")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func meter(limit: Int64) -> some View {
        let fraction = Double(usedBytes) / Double(max(limit, 1))
        let over = fraction >= 1
        let near = fraction >= 0.9

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("Torrent storage")
                Spacer()
                Text("\(ByteFormatting.bytes(usedBytes)) of \(ByteFormatting.bytes(limit))")
            }
            ProgressTrack(
                fraction: min(fraction, 1),
                tint: over ? SemanticColor.failure : near ? SemanticColor.warning : .accentColor,
                reduceMotion: reduceMotion
            )
            .frame(height: 3)

            if near || over {
                HStack(spacing: 6) {
                    Text(over ? "Over budget" : "Almost full")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(over ? SemanticColor.failure : SemanticColor.warning)
                    Spacer()
                    if !app.cleanup.plan.candidates.isEmpty {
                        Button("Clean…") {
                            store.activeSection = .readyToClean
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .font(.caption)
        .tabularNumerics()
        .contentShape(Rectangle())
        .onTapGesture {
            app.openSettings(tab: .storage)
        }
        .help("Storage budget — click to adjust")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Torrent storage: \(ByteFormatting.bytes(usedBytes)) used of \(ByteFormatting.bytes(limit)) budget")
    }
}
