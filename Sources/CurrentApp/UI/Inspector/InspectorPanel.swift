import SwiftUI
import AppKit
import CurrentCore

enum InspectorTab: Hashable {
    case overview
    case files
    case activity
    case rules
}

/// The details panel.
///
/// Was `.inspector(isPresented:)`, which brought a system-material background, a
/// system segmented picker and the system's own idea of a panel edge. This is a
/// plain column the shell sizes, so it can be dragged to any width and matches
/// the sidebar it faces across the window.
///
/// The tab strip slides (see `SegmentedPicker`) and the panes cross-fade in the
/// direction you moved, so switching from Overview to Files reads as travelling
/// sideways through one object rather than as replacing the panel's contents.
struct InspectorPanel: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let snapshot: TorrentSnapshot
    @State private var tab: InspectorTab = .overview
    @State private var fileNodes: [FileNode] = []
    @State private var fileNodesReady = false

    private var hasFiles: Bool { store.metadataCache[snapshot.id] != nil }

    private var tabs: [SegmentOption<InspectorTab>] {
        var options: [SegmentOption<InspectorTab>] = [
            SegmentOption(.overview, "Overview", symbol: "square.text.square"),
        ]
        if hasFiles {
            options.append(SegmentOption(.files, "Files", symbol: "folder"))
        }
        options.append(SegmentOption(.activity, "Activity", symbol: "waveform"))
        options.append(SegmentOption(.rules, "Rules", symbol: "slider.horizontal.3"))
        return options
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SegmentedPicker(selection: $tab, options: tabs, iconOnly: true)
                .padding(.horizontal, Chrome.panePadding)
                .padding(.bottom, Space.l)
            Hairline()

            pane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.chrome)
        // Falling back to Overview when the selected tab disappears — the Files
        // tab only exists once metadata resolves, and a magnet that loses it
        // would otherwise leave the panel showing nothing.
        .onChange(of: hasFiles) { _, has in
            if !has, tab == .files { tab = .overview }
        }
        .onChange(of: snapshot.id) { _, _ in
            // A different torrent is a different object. Rebuilding the file
            // tree lazily rather than here keeps switching rows cheap.
            fileNodesReady = false
            fileNodes = []
        }
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .overview:
            OverviewPane(snapshot: snapshot, failure: app.failures[snapshot.id])
        case .files:
            filesPane
        case .activity:
            ActivityPane(snapshot: snapshot)
        case .rules:
            RulesPane(snapshot: snapshot)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(snapshot.name)
                .typeStyle(Typo.heading)
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Space.s) {
                StatePill(state: app.failures[snapshot.id].map { TorrentState.failed($0) } ?? snapshot.state)

                if SwarmHealth(seeds: snapshot.swarm.connectedSeeds) == .rare && !snapshot.state.isComplete {
                    Chip(text: "Rare", symbol: "sparkles", tint: Theme.warning)
                }
                if snapshot.pinned {
                    Chip(text: "Pinned", symbol: "pin.fill")
                }

                Spacer(minLength: Space.m)

                Button {
                    store.togglePause(for: [snapshot.id])
                } label: {
                    Image(systemName: pauseSymbol)
                        .contentTransition(.symbolEffect(.replace.offUp))
                }
                .iconButton()
                .help(pauseHelp)

                Button {
                    app.revealInFinder(snapshot.id)
                } label: {
                    Image(systemName: "folder")
                }
                .iconButton()
                .help("Reveal in Finder")

                Button {
                    app.confirmRemoval(of: [snapshot.id])
                } label: {
                    Image(systemName: "trash")
                }
                .iconButton(isDestructive: true)
                .help("Remove")
            }
            .animation(Motion.adaptive(Motion.quick, reduceMotion: reduceMotion), value: pauseSymbol)
        }
        .padding(Chrome.panePadding)
    }

    private var pauseSymbol: String {
        if case .paused = snapshot.state { return "play.fill" }
        return "pause.fill"
    }

    private var pauseHelp: String {
        if case .paused = snapshot.state { return "Resume" }
        return "Pause"
    }

    // MARK: - Files pane

    @ViewBuilder
    private var filesPane: some View {
        if let metadata = store.metadataCache[snapshot.id] {
            if !fileNodesReady || fileNodes.isEmpty {
                Color.clear.onAppear { rebuildFileNodes(metadata: metadata) }
            }
            FileTreeEditor(
                nodes: Binding(
                    get: { fileNodes },
                    set: {
                        fileNodes = $0
                        store.setPriorities(FileTreeBuilder.flattenPriorities($0), for: snapshot.id)
                    }
                )
            )
        } else {
            EmptyStateView(
                symbol: "doc.text.magnifyingglass",
                title: "No file details yet",
                message: "Files become available once the torrent's metadata resolves."
            )
        }
    }

    private func rebuildFileNodes(metadata: TorrentMetadata) {
        let priorities = store.filePriorities[snapshot.id]
            ?? Array(repeating: .normal, count: metadata.files.count)
        fileNodes = FileTreeBuilder.build(from: metadata.files, priorities: priorities)
        fileNodesReady = true
    }
}

// MARK: - Shared pane furniture

/// A titled group of rows. The inspector is a stack of these.
///
/// The title sits *outside* the card as an overline rather than inside it as a
/// heading, which keeps the cards themselves pure content and makes a column of
/// four groups scannable by their labels alone.
private struct Group_<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let title {
                Text(title.uppercased())
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, Space.hair)
            }
            VStack(alignment: .leading, spacing: Space.hair, content: content)
                .padding(Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetCard()
        }
    }
}

private struct PaneScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl, content: content)
                .padding(Chrome.panePadding)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Overview pane

private struct OverviewPane: View {
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot
    let failure: EngineFailure?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        PaneScroll {
            if let failure {
                ErrorDetailsDisclosure(failure: failure)
            }

            progressCard

            Group_(title: "Transfer") {
                if case .downloading = snapshot.state {
                    StatRow(label: "Speed", value: ByteFormatting.rate(snapshot.downloadRate))
                }
                if snapshot.uploadRate > 1 {
                    StatRow(label: "Uploading at", value: ByteFormatting.rate(snapshot.uploadRate))
                }
                if let eta = snapshot.etaSeconds, snapshot.state.isActive {
                    StatRow(label: "Time remaining", value: ByteFormatting.eta(eta))
                }
                StatRow(label: "Downloaded", value: ByteFormatting.bytes(snapshot.downloadedBytes))
                StatRow(label: "Uploaded", value: ByteFormatting.bytes(snapshot.uploadedBytes))
                StatRow(label: "Share ratio", value: ByteFormatting.ratio(snapshot.shareRatio))
                StatRow(label: "Peers connected", value: "\(snapshot.swarm.connectedPeers)")
                StatRow(label: "Added", value: snapshot.addedAt.formatted(date: .abbreviated, time: .shortened))
                if let completed = snapshot.completedAt {
                    StatRow(label: "Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                }
            }

            SwarmHealthCard(
                health: SwarmHealth(seeds: snapshot.swarm.connectedSeeds),
                seeds: snapshot.swarm.connectedSeeds
            )

            saveLocation
        }
    }

    /// The panel's headline. A big tabular percentage that counts rather than
    /// cuts, over a thicker version of the same bar the list rows use — so the
    /// inspector reads as a magnification of the row you clicked, not as a
    /// different way of showing the same thing.
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(ByteFormatting.progress(snapshot.progress))
                    .typeStyle(Typo.display)
                    .tabularNumerics()
                    .numericTransition()
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Space.m)
                Text("\(ByteFormatting.bytes(snapshot.selectedBytes)) of \(ByteFormatting.bytes(snapshot.totalBytes))")
                    .typeStyle(Typo.caption)
                    .tabularNumerics()
                    .numericTransition()
                    .foregroundStyle(Theme.textSecondary)
            }
            ProgressTrack(fraction: snapshot.progress, tint: tint, reduceMotion: reduceMotion)
                .frame(height: 5)
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCard()
    }

    private var tint: Color {
        switch snapshot.state {
        case .failed: return Theme.failure
        case .seeding: return Theme.seeding
        case .completed: return Theme.complete
        case .paused, .resolving: return Theme.progressIdle
        default: return Theme.downloading
        }
    }

    private var saveLocation: some View {
        Group_(title: "Location") {
            HStack(spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(snapshot.saveDirectory.path)
                        .font(.monoStyle)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Space.m)
                Button("Open") {
                    NSWorkspace.shared.activateFileViewerSelecting([snapshot.saveDirectory])
                }
                .currentButton(.secondary, scale: .small)
            }
        }
    }
}

// MARK: - Activity pane

private struct ActivityPane: View {
    let snapshot: TorrentSnapshot

    var body: some View {
        PaneScroll {
            HStack(spacing: Space.l) {
                RateTile(symbol: "arrow.down", label: "Down", value: snapshot.downloadRate, tint: Theme.downloading)
                RateTile(symbol: "arrow.up", label: "Up", value: snapshot.uploadRate, tint: Theme.seeding)
            }

            Group_(title: "Swarm") {
                StatRow(label: "Connected seeds", value: "\(snapshot.swarm.connectedSeeds)")
                StatRow(label: "Known sources", value: "\(max(snapshot.swarm.knownSeeds, snapshot.swarm.connectedSeeds))")
                StatRow(label: "Connected peers", value: "\(snapshot.swarm.connectedPeers)")
            }

            Group_(title: "History") {
                StatRow(label: "Time seeding", value: ByteFormatting.duration(snapshot.activeSeedSeconds))
                if let last = snapshot.lastActivityAt {
                    StatRow(label: "Last activity", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }
        }
    }
}

/// A big number with its direction.
///
/// The heading is tinted; the number itself is not, and neither is the tile —
/// two filled colour blocks side by side made the Activity tab louder than the
/// thing it was reporting on.
private struct RateTile: View {
    let symbol: String
    let label: String
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                Text(label.uppercased())
                    .typeStyle(Typo.overline)
            }
            .foregroundStyle(tint)

            Text(ByteFormatting.rate(value))
                .typeStyle(Typo.title)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.l)
        .insetCard()
    }
}

// MARK: - Rules pane

private struct RulesPane: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot

    @State private var decisions: [DecisionRecord] = []

    private var record: TorrentRecord? { store.record(for: snapshot.id) }
    private var policy: SeedPolicy { record?.policy ?? .defaultPolicy }

    private static let options: [(value: String, title: String, detail: String)] = [
        ("balanced", "Balanced", "Stops after a 1.0× share ratio and 24 hours of seeding."),
        ("helpful", "Helpful", "Balanced rules — stays available while a torrent is rare."),
        ("temporary", "Temporary", "Seeds to the goal, then becomes ready for cleanup."),
        ("archive", "Archive", "Keeps seeding indefinitely to preserve the swarm."),
    ]

    var body: some View {
        PaneScroll {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("SEED POLICY")
                    .typeStyle(Typo.overline)
                    .foregroundStyle(Theme.textTertiary)
                // Keyed by name rather than by `SeedPolicy`, which carries
                // associated values and so doesn't compare usefully for a
                // radio group.
                RadioGroup(
                    selection: Binding(
                        get: { Self.key(policy) },
                        set: { store.setPolicy(Self.policy(for: $0), for: [snapshot.id]) }
                    ),
                    options: Self.options
                )
            }

            Group_ {
                Toggle(isOn: Binding(
                    get: { snapshot.pinned },
                    set: { store.setPinned($0, for: [snapshot.id]) }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Pin from cleanup")
                            .typeStyle(Typo.label)
                        Text("Automatic cleanup will never touch this torrent.")
                            .typeStyle(Typo.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .currentSwitch()
            }

            if !decisions.isEmpty {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text("RECENT AUTOMATION")
                        .typeStyle(Typo.overline)
                        .foregroundStyle(Theme.textTertiary)
                    // Every automatic behaviour in this app has to be able to
                    // say why it happened — see AGENTS.md. This is where those
                    // reason strings surface, so they are content, not a log.
                    ForEach(decisions.prefix(6)) { decision in
                        DecisionRow(decision: decision)
                    }
                }
            }
        }
        .onAppear(perform: loadDecisions)
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

    private func loadDecisions() {
        Task.detached(priority: .utility) { [database = app.database] in
            let all = database.recentDecisions(limit: 40)
            await MainActor.run {
                decisions = all.filter { $0.torrentID == snapshot.id }
            }
        }
    }
}

struct DecisionRow: View {
    let decision: DecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.m) {
                Text(decision.kind.rawValue)
                    .typeStyle(Typo.label)
                    .foregroundStyle(Theme.text)
                Spacer(minLength: Space.m)
                Text(decision.date, format: .relative(presentation: .named))
                    .typeStyle(Typo.caption)
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(decision.reasons, id: \.self) { reason in
                HStack(alignment: .top, spacing: Space.s) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Theme.textQuaternary)
                        .padding(.top, 2)
                    Text(reason)
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetCard()
    }
}
