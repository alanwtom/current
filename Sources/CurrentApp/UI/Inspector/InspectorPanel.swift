import SwiftUI
import AppKit
import CurrentCore

enum InspectorTab: Hashable {
    case overview
    case files
    case activity
    case rules

    /// Left-to-right position in the tab strip, so a pane can travel in the
    /// same direction the pill just did. Fixed rather than looked up in the
    /// visible options, which are not a constant — Files only exists once a
    /// magnet's metadata has resolved.
    var rank: Int {
        switch self {
        case .overview: return 0
        case .files: return 1
        case .activity: return 2
        case .rules: return 3
        }
    }
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
    /// Which way the last tab change went: +1 rightwards, -1 leftwards. Drives
    /// the pane's travel so the panel reads as one object being scrolled
    /// sideways rather than as its contents being swapped out.
    @State private var travel: CGFloat = 1

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
            SegmentedPicker(selection: tabSelection, options: tabs, iconOnly: true)
                .padding(.horizontal, Chrome.panePadding)
                .padding(.bottom, Space.l)
            Hairline()

            // **The pane is keyed on the tab, and the `ZStack` around it is
            // what makes that mean anything.** This file has claimed since it
            // was written that the panes "cross-fade in the direction you
            // moved", and until now they did nothing at all: a bare `switch`
            // has no identity change for SwiftUI to transition, so Overview
            // became Files in a single frame while the pill above it slid
            // across — the one part of the panel that moved was the strip, and
            // the content it described just cut.
            ZStack {
                pane
                    .id(tab)
                    .transition(paneTransition)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The picker sets `tab` inside `withAnimation` already, but the
            // fallback below doesn't — a magnet losing its Files tab has to
            // land as gently as a click does.
            .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: tab)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.chrome)
        // Falling back to Overview when the selected tab disappears — the Files
        // tab only exists once metadata resolves, and a magnet that loses it
        // would otherwise leave the panel showing nothing.
        .onChange(of: hasFiles) { _, has in
            if !has, tab == .files {
                travel = -1
                tab = .overview
            }
        }
        .onChange(of: snapshot.id) { _, _ in
            // A different torrent is a different object. Rebuilding the file
            // tree lazily rather than here keeps switching rows cheap.
            fileNodesReady = false
            fileNodes = []
        }
    }

    /// Records which way the strip moved *before* handing the change on.
    ///
    /// It has to be the setter rather than an `onChange`: the pane is inserted
    /// during the same update that changes the tab, so a direction written
    /// afterwards is always one click stale — the first sideways move of a
    /// session would travel the wrong way, and every later one would repeat
    /// whichever way the previous one went.
    private var tabSelection: Binding<InspectorTab> {
        Binding(
            get: { tab },
            set: { next in
                travel = next.rank >= tab.rank ? 1 : -1
                tab = next
            }
        )
    }

    /// A cross-fade with a nudge. The distance is deliberately small — the
    /// panes are full-height columns of cards, and sliding one of those its own
    /// width would be a page turn in a 320pt panel.
    private var paneTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: travel * Motion.enterOffset)),
            removal: .opacity.combined(with: .offset(x: -travel * Motion.enterOffset))
        )
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

            HStack(spacing: Space.m) {
                StatePill(state: app.failures[snapshot.id].map { TorrentState.failed($0) } ?? snapshot.state)

                // Only when a tracker has actually reported the swarm. This chip
                // used to appear on anything paused or newly added, because
                // rarity was inferred from how many seeds we were connected to
                // — zero, in both cases.
                if SwarmHealth(swarm: snapshot.swarm) == .rare && !snapshot.state.isComplete {
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
                    .padding(.horizontal, Space.xs)
            }
            VStack(alignment: .leading, spacing: Space.xs, content: content)
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
                // The swarm's own size, straight from the tracker — the figure
                // a torrent page shows. Shown separately from "connected"
                // because the two are different questions and reading one as
                // the other is what made a 335-seed torrent look abandoned.
                if let seeds = snapshot.swarm.swarmSeeds {
                    StatRow(label: "Seeds in swarm", value: "\(seeds)")
                }
                if let peers = snapshot.swarm.swarmPeers {
                    StatRow(label: "Peers in swarm", value: "\(peers)")
                }
                StatRow(label: "Added", value: snapshot.addedAt.formatted(date: .abbreviated, time: .shortened))
                if let completed = snapshot.completedAt {
                    StatRow(label: "Completed", value: completed.formatted(date: .abbreviated, time: .shortened))
                }
            }

            // Nothing at all until a tracker has reported. A card explaining
            // that we don't know is worse than no card.
            let health = SwarmHealth(swarm: snapshot.swarm)
            if health.isKnown {
                SwarmHealthCard(
                    health: health,
                    seeds: snapshot.swarm.swarmSeeds ?? snapshot.swarm.knownSeeds
                )
            }

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
            ProgressTrack(
                fraction: snapshot.progress,
                tint: tint,
                reduceMotion: reduceMotion,
                flow: .of(snapshot.state, snapshot: snapshot)
            )
            .frame(height: Size.trackLarge)
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
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot

    var body: some View {
        PaneScroll {
            // **The graph replaced the two big rate tiles that used to sit
            // here, rather than joining them.** The tiles said "↓ 2.4 MB/s"
            // and "↑ 310 KB/s" in large type, which is the same two figures
            // the graph's own legend carries and the Overview pane states
            // again — three copies of one fact, and none of them answering the
            // question this tab is for, which is what the transfer has been
            // *doing*. A number is a snapshot; the shape is the activity.
            RateGraph(history: store.rates(for: snapshot.id))

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
        VStack(alignment: .leading, spacing: Space.m) {
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
                HStack(alignment: .top, spacing: Space.m) {
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
