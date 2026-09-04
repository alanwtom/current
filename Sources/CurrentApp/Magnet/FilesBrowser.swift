import SwiftUI
import AppKit
import CurrentCore

// MARK: - File tree editor (shared by magnet selection and the inspector)

/// Hierarchical file browser: tri-state checkboxes, per-node priority, filter,
/// and multi-select for bulk priority changes.
///
/// **Folders actually open now.** The previous version rendered only the top
/// level — it kept an `expandedFolders` set and a `depth` parameter and used
/// neither, so every row came out at depth 0 and a torrent that wrapped its
/// files in a directory showed exactly one line with no way past it. You could
/// not see, deselect, or prioritise an individual file inside a folder.
///
/// The rows are a **flattened** list rather than nested `ForEach`es. Walking the
/// tree once into `[(node, depth)]` is what makes the rest of this view simple:
/// selection, the filter, and keyboard order are all just operations on an
/// array, and there is no recursive view identity for SwiftUI to get confused
/// about when a folder opens.
struct FileTreeEditor: View {
    @Binding var nodes: [FileNode]
    var showsFooterSummary = true
    /// Set only by the magnet file picker, which is a modal overlay and has to
    /// take the keyboard from the library list itself. In the inspector, where
    /// this same editor also lives, autofocusing would steal focus from the
    /// library every time you selected a row.
    var autofocusFilter = false
    var onPrioritiesChanged: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var searchText = ""
    @State private var selectedIDs = Set<String>()
    @State private var expandedFolders = Set<String>()
    @State private var didAutoExpand = false

    private var filteredNodes: [FileNode] {
        FileTreeBuilder.filtered(nodes, query: searchText)
    }

    private var selectedBytes: Int64 { FileTreeBuilder.selectedBytes(nodes) }
    private var totalBytes: Int64 { FileTreeBuilder.totalSize(nodes) }

    /// One row per visible node, carrying its indent level.
    ///
    /// While filtering, everything is shown expanded: hiding a match inside a
    /// collapsed folder would mean typing a filename and being told nothing
    /// matched.
    private var rows: [Row] {
        var result: [Row] = []
        let forceOpen = !searchText.isEmpty
        func walk(_ nodes: [FileNode], depth: Int) {
            for node in nodes {
                result.append(Row(node: node, depth: depth))
                guard node.isFolder, forceOpen || expandedFolders.contains(node.id) else { continue }
                walk(node.children, depth: depth + 1)
            }
        }
        walk(filteredNodes, depth: 0)
        return result
    }

    private struct Row: Identifiable {
        let node: FileNode
        let depth: Int
        var id: String { node.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            CurrentField(
                "Filter files",
                text: $searchText,
                symbol: "magnifyingglass",
                autofocus: autofocusFilter
            )
            .padding(Space.l)
            Hairline()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { row in
                        NodeRow(
                            node: row.node,
                            depth: row.depth,
                            isExpanded: expandedFolders.contains(row.node.id) || !searchText.isEmpty,
                            isSelected: selectedIDs.contains(row.node.id),
                            onToggleExpand: { toggleExpand(row.node) },
                            onToggleInclude: { toggle(node: row.node, value: $0) },
                            onSelect: { select(row.node) },
                            onPriorityChange: { applyPriority(to: row.node.id, $0) }
                        )
                    }
                }
                .padding(.vertical, Space.xs)
                .padding(.horizontal, Space.s)
            }
            .scrollIndicators(.automatic)
            .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: rows.map(\.id))
            .overlay {
                if rows.isEmpty && !searchText.isEmpty {
                    Text("No files match “\(searchText)”")
                        .typeStyle(Typo.caption)
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            if showsFooterSummary {
                Hairline()
                footer
            }

            if selectedIDs.count > 1 {
                Hairline()
                bulkBar
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: selectedIDs.count > 1)
        .onAppear(perform: autoExpand)
        // Also when the tree arrives, not only when the view does. In the
        // inspector the nodes are built in a sibling view's `onAppear`, so on
        // the first pass `nodes` is still empty — `autoExpand` had nothing to
        // walk, marked itself done, and every folder stayed shut.
        .onChange(of: nodes.count) { _, _ in autoExpand() }
    }

    // MARK: Pieces

    private var footer: some View {
        HStack(spacing: Space.m) {
            Text("Download \(ByteFormatting.bytes(selectedBytes))")
                .typeStyle(Typo.label)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.text)
            Text("of \(ByteFormatting.bytes(totalBytes))")
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .foregroundStyle(Theme.textTertiary)
            Spacer()
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.l)
    }

    private var bulkBar: some View {
        HStack(spacing: Space.l) {
            Text("\(selectedIDs.count) selected")
                .typeStyle(Typo.caption)
                .foregroundStyle(Theme.textSecondary)
            Menu("Set priority") {
                priorityMenuContents { priority in
                    for id in selectedIDs {
                        applyPriority(to: id, priority)
                    }
                    selectedIDs.removeAll()
                }
            }
            .menuStyle(.button)
            .buttonStyle(CurrentButton(role: .secondary, scale: .small))
            .fixedSize()
            Spacer()
            Button("Clear") { selectedIDs.removeAll() }
                .currentButton(.ghost, scale: .small)
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .background(Theme.fillSubtle)
    }

    @ViewBuilder
    private func priorityMenuContents(action: @escaping (FilePriority) -> Void) -> some View {
        Button("Skip") { action(.skip) }
        Button("Normal") { action(.normal) }
        Button("High") { action(.high) }
        Button("First") { action(.first) }
    }

    // MARK: Interaction

    /// Opens the top level, and keeps opening while a folder is the only thing
    /// inside its parent.
    ///
    /// Most torrents are one wrapper directory around the actual files, and
    /// making someone click through that wrapper every time to reach anything is
    /// pure ceremony. A tree that branches is left alone.
    private func autoExpand() {
        guard !didAutoExpand, !nodes.isEmpty else { return }
        didAutoExpand = true
        var open = Set<String>()
        var level = nodes
        while level.count == 1, let only = level.first, only.isFolder {
            open.insert(only.id)
            level = only.children
        }
        for node in nodes where node.isFolder {
            open.insert(node.id)
        }
        expandedFolders = open
    }

    private func toggleExpand(_ node: FileNode) {
        guard node.isFolder else { return }
        withAnimation(Motion.spring(Motion.quick, reduceMotion: reduceMotion)) {
            if expandedFolders.contains(node.id) {
                expandedFolders.remove(node.id)
            } else {
                expandedFolders.insert(node.id)
            }
        }
    }

    /// Plain click selects one row, ⌘-click adds or removes.
    ///
    /// No ⇧-click range here, unlike the library list: a range across a tree
    /// whose visible rows change as folders open is a different problem, and
    /// silently selecting collapsed children would be worse than not offering
    /// it. Folder-level priority already covers "everything in here".
    private func select(_ node: FileNode) {
        if NSEvent.modifierFlags.contains(.command) {
            if selectedIDs.contains(node.id) {
                selectedIDs.remove(node.id)
            } else {
                selectedIDs.insert(node.id)
            }
        } else if node.isFolder {
            toggleExpand(node)
            selectedIDs = [node.id]
        } else {
            selectedIDs = [node.id]
        }
    }

    // MARK: Mutations

    private func toggle(node: FileNode, value: Bool) {
        nodes = FileTreeBuilder.setSelection(nodes, id: node.id, selected: value)
        onPrioritiesChanged?()
    }

    private func applyPriority(to id: String, _ priority: FilePriority) {
        nodes = Self.settingPriority(nodes, id: id, priority: priority)
        onPrioritiesChanged?()
    }

    static func settingPriority(
        _ nodes: [FileNode], id: String, priority: FilePriority
    ) -> [FileNode] {
        var result = nodes
        mutate(&result, id: id, priority: priority)
        return result
    }

    private static func mutate(_ nodes: inout [FileNode], id: String, priority: FilePriority) -> Bool {
        for index in nodes.indices {
            if nodes[index].id == id {
                assign(&nodes[index], priority: priority)
                return true
            }
            if !nodes[index].children.isEmpty,
               mutate(&nodes[index].children, id: id, priority: priority) {
                nodes[index].priority = aggregate(of: nodes[index].children)
                return true
            }
        }
        return false
    }

    private static func assign(_ node: inout FileNode, priority: FilePriority) {
        node.priority = priority
        if !node.children.isEmpty {
            for index in node.children.indices {
                assign(&node.children[index], priority: priority)
            }
        }
    }

    private static func aggregate(of children: [FileNode]) -> FilePriority {
        let values = children.map(\.priority.rawValue)
        if values.allSatisfy({ $0 == 0 }) { return .skip }
        return FilePriority(rawValue: values.max() ?? 4)
    }
}

// MARK: - Node row

private struct NodeRow: View {
    let node: FileNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    var onToggleExpand: () -> Void
    var onToggleInclude: (Bool) -> Void
    var onSelect: () -> Void
    var onPriorityChange: (FilePriority) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private var selectionState: FileNode.SelectionState {
        FileTreeBuilder.selectionState(of: node)
    }

    private var isSkipped: Bool { node.priority == .skip && !node.isFolder }

    var body: some View {
        HStack(spacing: Space.m) {
            chevron
            checkbox

            Image(systemName: node.isFolder ? "folder.fill" : "doc")
                .font(.system(size: Size.iconSmall))
                .foregroundStyle(node.isFolder ? Theme.textSecondary : Theme.textQuaternary)

            Text(node.name)
                .typeStyle(Typo.label)
                .strikethrough(isSkipped)
                .foregroundStyle(isSkipped ? Theme.textTertiary : Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)

            if !node.isFolder && node.priority != .normal && node.priority != .skip {
                Chip(text: node.priority.label, tint: Theme.accent)
            }

            Spacer(minLength: Space.m)

            Text(ByteFormatting.bytes(node.size))
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .foregroundStyle(Theme.textTertiary)

            priorityMenu
        }
        // Indented from the chevron's own column, so a nested file lines up
        // under its folder's name rather than under its disclosure arrow.
        .padding(.leading, CGFloat(depth) * 16 + Space.s)
        .padding(.trailing, Space.s)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: Radius.s, style: .continuous)
                .fill(isSelected ? Theme.fillMuted : (isHovering ? Theme.fillSubtle : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(node.priority == .skip ? "Include" : "Skip") {
                onToggleInclude(node.priority == .skip)
            }
            Menu("Priority") {
                Button("Skip") { onPriorityChange(.skip) }
                Button("Normal") { onPriorityChange(.normal) }
                Button("High") { onPriorityChange(.high) }
                Button("First") { onPriorityChange(.first) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    /// One glyph that rotates, and a fixed-width slot so files line up with
    /// folders instead of shifting left by an arrow's width.
    @ViewBuilder
    private var chevron: some View {
        if node.isFolder {
            Button(action: onToggleExpand) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .animation(Motion.spring(Motion.quick, reduceMotion: reduceMotion), value: isExpanded)
            .accessibilityLabel(isExpanded ? "Collapse folder" : "Expand folder")
        } else {
            Spacer().frame(width: 12)
        }
    }

    private var checkbox: some View {
        Button {
            onToggleInclude(selectionState == .none || selectionState == .partial)
        } label: {
            RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                .fill(selectionState == .none ? Theme.fillMuted : Theme.accent)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xs, style: .continuous)
                        .strokeBorder(selectionState == .none ? Theme.stroke : .clear, lineWidth: Size.hairline)
                )
                .frame(width: 14, height: 14)
                .overlay {
                    switch selectionState {
                    case .all:
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(Theme.textOnAccent)
                    case .partial:
                        Capsule()
                            .fill(Theme.textOnAccent)
                            .frame(width: 7, height: 1.5)
                    case .none:
                        EmptyView()
                    }
                }
        }
        .buttonStyle(.plain)
        .animation(Motion.adaptive(Motion.instant, reduceMotion: reduceMotion), value: selectionState)
        .help(selectionState == .all ? "Deselect" : "Select")
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        let state = switch selectionState {
        case .all: "Selected"
        case .partial: "Partially selected"
        case .none: "Not selected"
        }
        return "\(state): \(node.name), \(ByteFormatting.bytes(node.size))"
    }

    @ViewBuilder
    private var priorityMenu: some View {
        if !node.isFolder {
            Menu {
                Button("Skip") { onPriorityChange(.skip) }
                Button("Normal") { onPriorityChange(.normal) }
                Button("High") { onPriorityChange(.high) }
                Button("First") { onPriorityChange(.first) }
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: Size.iconSmall))
                    .foregroundStyle(Theme.textTertiary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 18)
            .fixedSize()
            // Appears on hover or when the row matters. A needle icon on every
            // one of two hundred rows is visual noise.
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Download priority")
        }
    }
}

// MARK: - Magnet file selection sheet

/// Full file picker, opened from "Choose files…" on the magnet flow card.
///
/// Presented by `modalSurface` rather than `.sheet`, so it takes a `close`
/// closure — `\.dismiss` does nothing outside a real presentation — and draws no
/// background of its own, because the modal surface draws the card.
struct MagnetSelectionSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var flow: MagnetFlowCenter
    @EnvironmentObject private var store: LibraryStore

    let metadata: TorrentMetadata
    let close: () -> Void
    @State private var nodes: [FileNode]

    init(metadata: TorrentMetadata, close: @escaping () -> Void) {
        self.metadata = metadata
        self.close = close
        _nodes = State(initialValue: FileTreeBuilder.build(from: metadata.files))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            FileTreeEditor(nodes: $nodes, showsFooterSummary: false, autofocusFilter: true)
            Hairline()
            footerBar
        }
        .modalSize(width: 560, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(metadata.displayName)
                .typeStyle(Typo.title)
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Text("\(metadata.files.count) files · \(ByteFormatting.bytes(metadata.totalSize))")
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.xxl)
    }

    private var selectedBytes: Int64 { FileTreeBuilder.selectedBytes(nodes) }

    private var footerBar: some View {
        HStack(spacing: Space.m) {
            Text("\(ByteFormatting.bytes(selectedBytes)) selected")
                .typeStyle(Typo.caption)
                .tabularNumerics()
                .numericTransition()
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Button("Cancel", role: .cancel) {
                close()
                Task { await app.cancelMagnetSelection() }
            }
            .currentButton(.ghost)
            Button {
                let priorities = FileTreeBuilder.flattenPriorities(nodes)
                Task {
                    await app.applyMagnetSelection(priorities)
                    close()
                }
            } label: {
                Text("Download").tabularNumerics()
            }
            .currentButton(.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedBytes == 0)
        }
        .padding(Space.xxl)
    }
}
