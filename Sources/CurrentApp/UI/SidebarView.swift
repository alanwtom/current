import SwiftUI
import Combine
import CurrentCore

/// The sidebar's section counts, deliberately updated at human speed rather
/// than at the engine's tick.
///
/// Recomputing these straight from the library every tick is what crashed the
/// app: several counts depend on jittery per-tick data, so a badge would appear
/// and disappear continuously, and every one of those changes made the layout
/// re-measure. On a tick that never settles, AppKit runs constraint passes until
/// it hits its own limit and traps.
///
/// The custom sidebar has fixed widths now, so it is no longer AppKit
/// renegotiating a column — but coalescing is still right on its own merits.
/// Nobody reads a section count that flickers once a second.
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
        // Publishing only on a real change keeps the sidebar completely still
        // between changes.
        if next != counts { counts = next }
    }
}

// MARK: - Sidebar

/// The app's own sidebar.
///
/// `List(selection:).listStyle(.sidebar)` is gone. It was giving the app three
/// of the most recognisable stock-macOS details all at once: the translucent
/// vibrant material, the system's rounded blue selection capsule, and the
/// system's section-header type. This draws all three itself — a flat chrome
/// surface, a neutral selection pill with a small accent bar at its leading
/// edge, and uppercase overline headers.
///
/// The selection indicator slides. One `matchedGeometryEffect` shared across all
/// the rows, so moving from Downloading to Seeding shows the pill travelling
/// rather than fading out and in somewhere else. It is the same trick as the
/// segmented control, for the same reason: motion between two states tells you
/// they are related.
struct SidebarView: View, Equatable {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var counts: SidebarCounts

    /// The selected section as a **value**, with a closure to change it —
    /// rather than a reference to `LibraryStore`.
    ///
    /// The store publishes on every engine batch (~1 Hz), so observing it here
    /// would re-render the sidebar once a second forever, which is the churn
    /// this app has twice died of. The previous version dodged that by holding
    /// a plain, unobserved reference — and then never noticed the section
    /// changing at all: clicking "Seeding" switched the list while the highlight
    /// stayed on "All".
    ///
    /// A value plus `Equatable` gets both: the body re-runs when the section
    /// actually changes, and not on any other beat.
    let section: SidebarSection
    let onSelect: (SidebarSection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var indicator

    /// `nonisolated` because SwiftUI compares views off the main actor, and
    /// comparing two plain enum values needs nothing from it.
    nonisolated static func == (lhs: SidebarView, rhs: SidebarView) -> Bool {
        lhs.section == rhs.section
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xxl) {
                    group("Library", sections: SidebarSection.library)
                    group("Smart", sections: SidebarSection.smart)
                }
                .padding(.horizontal, Space.m)
                .padding(.top, Space.m)
                .padding(.bottom, Space.xl)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)

            // No rule above the meter. It is already the only thing down here
            // and the space around it says so; a line would be the last drawn
            // seam left in the window's frame, which is what makes one look
            // like a leftover rather than a decision.
            StorageMeter()
                .padding(.horizontal, Space.l)
                .padding(.top, Space.m)
                .padding(.bottom, Space.l)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.chrome)
    }

    private func group(_ title: String, sections: [SidebarSection]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title.uppercased())
                .typeStyle(Typo.overline)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, Space.m)
                .padding(.bottom, Space.s)

            ForEach(sections, id: \.self) { item in
                row(item)
            }
        }
    }

    private func row(_ item: SidebarSection) -> some View {
        let isSelected = section == item
        let count = counts.count(for: item)
        // Needs-attention and ready-to-clean are the two sections that exist to
        // be noticed. They tint only when they actually hold something —
        // a permanently coloured row stops meaning anything.
        let isFlagged = (item == .attention || item == .readyToClean) && count > 0

        return Button {
            guard !isSelected else { return }
            onSelect(item)
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: item.symbol)
                    .font(.system(size: Size.iconSmall, weight: .medium))
                    .frame(width: Size.iconColumn)
                    .foregroundStyle(glyphColor(isSelected: isSelected, flagged: isFlagged))
                Text(item.title)
                    .typeStyle(Typo.label)
                    .foregroundStyle(isSelected ? Theme.text : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Space.s)
                badge(count)
            }
            .padding(.horizontal, Space.m)
            .frame(height: Size.sidebarRow)
            .background {
                if isSelected {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Radius.m, style: .continuous)
                            .fill(Theme.fillMuted)
                        // The accent, spent once: a 2pt bar rather than a
                        // filled capsule. It marks the row without turning it
                        // into the loudest thing in the window.
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: 2.5, height: Size.sidebarRow - 14)
                            .padding(.leading, 2)
                    }
                    .matchedGeometryEffect(id: "sidebar.selection", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverFill(Radius.m, active: !isSelected)
        .accessibilityLabel(count > 0 ? "\(item.title), \(count)" : item.title)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func glyphColor(isSelected: Bool, flagged: Bool) -> Color {
        if flagged { return isSelected ? Theme.warning : Theme.warning.opacity(0.8) }
        return isSelected ? Theme.text : Theme.textTertiary
    }

    /// Always present, always the same width.
    ///
    /// This badge used to be inserted and removed as counts crossed zero, and to
    /// grow with the number — which changes how wide the sidebar wants to be.
    /// The split view then renegotiated its column width on every engine tick,
    /// and that never settled: AppKit ran constraint passes until it gave up and
    /// killed the app about half a minute after launch. The sidebar is a fixed
    /// width now so the stakes are lower, but a number that jitters its own
    /// width still looks broken. Don't make this size to its content.
    private func badge(_ count: Int) -> some View {
        Text(count > 0 ? (count > 999 ? "999+" : "\(count)") : "")
            .typeStyle(Typo.caption)
            .tabularNumerics()
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 30, alignment: .trailing)
    }
}

// MARK: - Storage meter

/// Quiet budget indicator pinned to the sidebar bottom. Appears only once a
/// budget exists; clicking opens the storage pane of Settings.
struct StorageMeter: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var usedBytes: Int64 { store.usedStorageBytes }

    var body: some View {
        Group {
            if let limit = settings.storageLimitBytes {
                meter(limit: limit)
            } else if usedBytes > 0 {
                Button {
                    app.openSettings(tab: .storage)
                } label: {
                    HStack(spacing: Space.s) {
                        Image(systemName: "internaldrive")
                            .font(.system(size: Size.iconSmall, weight: .medium))
                        Text(ByteFormatting.bytes(usedBytes))
                            .tabularNumerics()
                            .numericTransition()
                        Spacer(minLength: 0)
                    }
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(height: Size.controlS)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hoverFill(Radius.s)
            }
        }
    }

    private func meter(limit: Int64) -> some View {
        let fraction = Double(usedBytes) / Double(max(limit, 1))
        let over = fraction >= 1
        let near = fraction >= 0.9

        return VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Text("Storage")
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: Space.xs)
                Text(ByteFormatting.bytes(usedBytes))
                    .foregroundStyle(over ? Theme.failure : near ? Theme.warning : Theme.textSecondary)
                    .numericTransition()
                Text("/ \(ByteFormatting.bytes(limit))")
                    .foregroundStyle(Theme.textQuaternary)
            }
            .typeStyle(Typo.caption)
            .tabularNumerics()

            ProgressTrack(
                fraction: min(fraction, 1),
                tint: over ? Theme.failure : near ? Theme.warning : Theme.accent,
                reduceMotion: reduceMotion
            )
            .frame(height: Size.track)

            if near || over {
                HStack(spacing: Space.s) {
                    Text(over ? "Over budget" : "Almost full")
                        .typeStyle(Typo.caption)
                        .foregroundStyle(over ? Theme.failure : Theme.warning)
                    Spacer(minLength: 0)
                    if !app.cleanup.plan.candidates.isEmpty {
                        Button("Clean") {
                            store.activeSection = .readyToClean
                        }
                        .currentButton(.secondary, scale: .small)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(Motion.spring(reduceMotion: reduceMotion), value: near || over)
        .contentShape(Rectangle())
        .onTapGesture { app.openSettings(tab: .storage) }
        .help("Storage budget — click to adjust")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Torrent storage: \(ByteFormatting.bytes(usedBytes)) used of \(ByteFormatting.bytes(limit)) budget")
    }
}
