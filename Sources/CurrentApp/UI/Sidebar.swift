import SwiftUI
import Combine
import CurrentCore

/// The sidebar's section counts, deliberately updated at human speed rather
/// than at the engine's tick.
///
/// Recomputing these straight from the library every tick is what crashed the
/// app: several of the counts depend on jittery per-tick data (the "Rare" count
/// tracks connected seeds, which wobbles every second), so a badge would appear
/// and disappear continuously. Each of those changes makes the split view
/// re-measure its sidebar column, and re-measuring on every single tick never
/// settles — AppKit kept running constraint passes on the window until it hit
/// its own limit and trapped, killing the app about half a minute in.
///
/// Coalescing here fixes that at the source and is worth having anyway: nobody
/// reads a section count that flickers once a second.
@MainActor
final class SidebarCounts: ObservableObject {

    /// Slow enough that the counts read as stable, fast enough to feel live.
    private static let tick: TimeInterval = 2

    @Published private(set) var counts: [SidebarSection: Int] = [:]

    private var cancellables = Set<AnyCancellable>()

    init(library: LibraryStore, cleanup: CleanupCenter) {
        recompute(library: library, cleanup: cleanup)

        for publisher in [library.objectWillChange, cleanup.objectWillChange] {
            publisher
                .throttle(for: .seconds(Self.tick), scheduler: RunLoop.main, latest: true)
                .sink { [weak self, weak library, weak cleanup] _ in
                    MainActor.assumeIsolated {
                        guard let self, let library, let cleanup else { return }
                        self.recompute(library: library, cleanup: cleanup)
                    }
                }
                .store(in: &cancellables)
        }
    }

    func count(for section: SidebarSection) -> Int { counts[section] ?? 0 }

    private func recompute(library: LibraryStore, cleanup: CleanupCenter) {
        var next: [SidebarSection: Int] = [:]
        for section in SidebarSection.library + SidebarSection.smart {
            next[section] = section == .readyToClean
                ? cleanup.plan.candidates.count
                : library.count(for: section)
        }
        // Publishing only on a real change keeps the sidebar — and the column
        // width negotiation it drives — completely still between changes.
        if next != counts { counts = next }
    }
}

struct Sidebar: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var counts: SidebarCounts

    /// Plain reference, not an @EnvironmentObject: the sidebar must not
    /// re-render on every engine tick. See `SidebarCounts`.
    let store: LibraryStore

    private var section: Binding<SidebarSection?> {
        Binding(
            get: { store.activeSection },
            set: { if let value = $0 { store.activeSection = value } }
        )
    }

    var body: some View {
        List(selection: section) {
            Section("Library") {
                ForEach(SidebarSection.library, id: \.self) { section in
                    SidebarRow(
                        section: section,
                        count: counts.count(for: section)
                    )
                    .tag(section)
                }
            }

            Section("Smart") {
                ForEach(SidebarSection.smart, id: \.self) { section in
                    SidebarRow(
                        section: section,
                        count: counts.count(for: section),
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
    let section: SidebarSection
    let count: Int
    var emphasized = false

    /// Width of the count badge. Fixed on purpose — see `body`.
    private static let badgeWidth: CGFloat = 30

    private var displayCount: Int? { count > 0 ? count : nil }

    /// Capped so a big library can't widen the badge. Counts this high are
    /// "a lot" to a reader anyway.
    private var badgeText: String {
        guard let displayCount else { return "" }
        return displayCount > 999 ? "999+" : "\(displayCount)"
    }

    var body: some View {
        HStack {
            Label(section.title, systemImage: section.symbol)
                .foregroundStyle(emphasized && (displayCount ?? 0) > 0 ? Color.accentColor : .primary)
            Spacer()
            // Always present, always the same width. This badge used to be
            // inserted and removed as counts crossed zero, and to grow with the
            // number — which changes how wide the sidebar wants to be. The
            // split view then renegotiated its column width on every engine
            // tick, and that renegotiation never settled: AppKit kept running
            // constraint passes until it gave up and killed the app about half
            // a minute after launch. Keeping the row's width constant is what
            // stops that, so don't make this badge size to its content.
            Text(badgeText)
                .font(.caption.tabularNumerics().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: Self.badgeWidth, alignment: .trailing)
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
