import SwiftUI
import CurrentCore

enum InspectorTab: Hashable {
    case overview
    case files
    case activity
    case rules
}

struct InspectorView: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var store: LibraryStore

    let snapshot: TorrentSnapshot
    @State private var tab: InspectorTab = .overview
    @State private var fileNodes: [FileNode] = []
    @State private var fileNodesReady = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Picker("", selection: $tab) {
                Text("Overview").tag(InspectorTab.overview)
                if store.metadataCache[snapshot.id] != nil {
                    Text("Files").tag(InspectorTab.files)
                }
                Text("Activity").tag(InspectorTab.activity)
                Text("Rules").tag(InspectorTab.rules)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            Group {
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
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.name)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                HStack(spacing: 6) {
                    Button {
                        store.togglePause(for: [snapshot.id])
                    } label: {
                        Image(systemName: pauseSymbol)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .help(pauseHelp)

                    Button {
                        app.revealInFinder(snapshot.id)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .help("Reveal in Finder")

                    Button {
                        app.confirmRemoval(of: [snapshot.id])
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .help("Remove")
                }
            }

            HStack(spacing: 6) {
                StatePill(state: app.failures[snapshot.id].map { TorrentState.failed($0) } ?? snapshot.state)
                if SwarmHealth(seeds: snapshot.swarm.connectedSeeds) == .rare && !snapshot.state.isComplete {
                    Label("Rare torrent", systemImage: "sparkles")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(SemanticColor.warning)
                }
                Spacer()
            }
        }
        .padding(16)
    }

    private var pauseSymbol: String {
        if case .paused = snapshot.state { return "play.fill" }
        return "pause.fill"
    }

    private var pauseHelp: String {
        if case .paused = snapshot.state { return "Resume" }
        return "Pause"
    }

    // MARK: Files pane

    @ViewBuilder
    private var filesPane: some View {
        let metadata = store.metadataCache[snapshot.id]
        if let metadata {
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

// MARK: - Overview pane

private struct OverviewPane: View {
    @EnvironmentObject private var store: LibraryStore
    let snapshot: TorrentSnapshot
    let failure: EngineFailure?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let failure {
                    ErrorDetailsDisclosure(failure: failure)
                }

                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ByteFormatting.progress(snapshot.progress))
                            .font(.title2.weight(.semibold).tabularNumerics())
                        Spacer()
                        Text("\(ByteFormatting.bytes(snapshot.selectedBytes)) of \(ByteFormatting.bytes(snapshot.totalBytes))")
                            .font(.callout.tabularNumerics())
                            .foregroundStyle(.secondary)
                    }
                    ProgressTrack(fraction: snapshot.progress, tint: tint, reduceMotion: reduceMotion)
                        .frame(height: 6)
                }
                .padding(14)
                .background(cardBackground)

                statsCard

                SwarmHealthCard(
                    health: SwarmHealth(seeds: snapshot.swarm.connectedSeeds),
                    seeds: snapshot.swarm.connectedSeeds
                )

                saveLocationCard
            }
            .padding(16)
        }
    }

    private var tint: Color {
        switch snapshot.state {
        case .seeding: return SemanticColor.seeding
        case .completed: return SemanticColor.complete
        default: return SemanticColor.downloading
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private var saveLocationCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Saved in")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(snapshot.saveDirectory.path)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([snapshot.saveDirectory])
            }
            .controlSize(.small)
        }
        .padding(14)
        .background(cardBackground)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
            .fill(Color.primary.opacity(0.035))
    }
}

// MARK: - Activity pane

private struct ActivityPane: View {
    let snapshot: TorrentSnapshot

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                rateGrid

                VStack(alignment: .leading, spacing: 4) {
                    StatRow(label: "Connected seeds", value: "\(snapshot.swarm.connectedSeeds)")
                    StatRow(label: "Known sources", value: "\(max(snapshot.swarm.knownSeeds, snapshot.swarm.connectedSeeds))")
                    StatRow(label: "Connected peers", value: "\(snapshot.swarm.connectedPeers)")
                    StatRow(label: "Time seeding", value: ByteFormatting.duration(snapshot.activeSeedSeconds))
                    if let last = snapshot.lastActivityAt {
                        StatRow(label: "Last activity", value: last.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                        .fill(Color.primary.opacity(0.035))
                )
            }
            .padding(16)
        }
    }

    private var rateGrid: some View {
        HStack(spacing: 12) {
            RateTile(symbol: "arrow.down", label: "Down", value: snapshot.downloadRate, color: SemanticColor.downloading)
            RateTile(symbol: "arrow.up", label: "Up", value: snapshot.uploadRate, color: SemanticColor.seeding)
        }
    }
}

private struct RateTile: View {
    let symbol: String
    let label: String
    let value: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(color)
            Text(ByteFormatting.rate(value))
                .font(.title3.weight(.semibold).tabularNumerics())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                .fill(color.opacity(0.07))
        )
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

    private static let options: [(SeedPolicy, String, String)] = [
        (.balanced, "Balanced", "Stops after a 1.0× share ratio and 24 hours of seeding."),
        (.helpful, "Helpful", "Balanced rules — stays available while a torrent is rare."),
        (.temporary, "Temporary", "Seeds to the goal, then becomes ready for cleanup."),
        (.archive, "Archive", "Keeps seeding indefinitely to preserve the swarm."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Seed policy")
                    .font(.subheadline.weight(.semibold))

                VStack(spacing: 8) {
                    ForEach(Self.options, id: \.1) { option, title, detail in
                        PolicyCard(
                            title: title,
                            detail: detail,
                            isSelected: isOption(option),
                            action: { store.setPolicy(option, for: [snapshot.id]) }
                        )
                    }
                }

                Toggle(isOn: Binding(
                    get: { snapshot.pinned },
                    set: { store.setPinned($0, for: [snapshot.id]) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pin from cleanup")
                            .font(.callout.weight(.medium))
                        Text("Automatic cleanup will never touch this torrent.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if !decisions.isEmpty {
                    Text("Recent automation")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(decisions.prefix(6)) { decision in
                            DecisionRow(decision: decision)
                        }
                    }
                }
            }
            .padding(16)
        }
        .onAppear(perform: loadDecisions)
    }

    private func isOption(_ option: SeedPolicy) -> Bool {
        policyLabel(option) == policyLabel(policy)
    }

    private func policyLabel(_ p: SeedPolicy) -> String {
        switch p {
        case .balanced: return "balanced"
        case .helpful: return "helpful"
        case .archive: return "archive"
        case .temporary: return "temporary"
        case .custom: return "custom"
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

struct PolicyCard: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.5))
                    .font(.body)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.35) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

struct DecisionRow: View {
    let decision: DecisionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(decision.kind.rawValue)
                    .font(.callout.weight(.semibold))
                Spacer()
                Text(decision.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(decision.reasons, id: \.self) { reason in
                Label(reason, systemImage: "text.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Layout.cornerM, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }
}
