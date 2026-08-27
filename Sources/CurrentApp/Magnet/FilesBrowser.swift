import SwiftUI
import CurrentCore

// MARK: - File tree editor (shared by magnet selection and the inspector)

/// Hierarchical file browser: tri-state checkboxes, per-node priority,
/// search filtering, multi-select with bulk priority changes.
struct FileTreeEditor: View {
    @Binding var nodes: [FileNode]
    var showsFooterSummary = true
    var onPrioritiesChanged: (() -> Void)?

    @State private var searchText = ""
    @State private var selectedIDs = Set<String>()
    @State private var expandedFolders = Set<String>()

    private var filteredNodes: [FileNode] {
        FileTreeBuilder.filtered(nodes, query: searchText)
    }

    private var selectedBytes: Int64 { FileTreeBuilder.selectedBytes(nodes) }
    private var totalBytes: Int64 { FileTreeBuilder.selectedBytes(nodes.map(unskippedTotal)) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            List(selection: $selectedIDs) {
                ForEach(filteredNodes) { node in
                    NodeRow(
                        node: node,
                        depth: 0,
                        expandedFolders: $expandedFolders,
                        onToggle: { selected, value in toggle(node: selected, value: value) },
                        onPriorityChange: { target, priority in applyPriority(to: target, priority) }
                    )
                    .tag(node.id)
                }
            }
            .listStyle(.plain)

            if showsFooterSummary {
                Divider()
                footer
            }

            if selectedIDs.count > 1 {
                Divider()
                bulkBar
            }
        }
    }

    // MARK: Pieces

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Filter files", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("Download \(ByteFormatting.bytes(selectedBytes)) of \(ByteFormatting.bytes(totalBytes))")
                .font(.callout.tabularNumerics().weight(.medium))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var bulkBar: some View {
        HStack(spacing: 10) {
            Text("\(selectedIDs.count) selected")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Menu("Set priority") {
                priorityMenuContents { priority in
                    for id in selectedIDs {
                        applyPriority(to: id, priority)
                    }
                    selectedIDs.removeAll()
                }
            }
            .font(.caption)
            .controlSize(.small)
            Spacer()
            Button("Clear") {
                selectedIDs.removeAll()
            }
            .font(.caption)
            .controlSize(.small)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private func priorityMenuContents(action: @escaping (FilePriority) -> Void) -> some View {
        Button("Skip") { action(.skip) }
        Button("Normal") { action(.normal) }
        Button("High") { action(.high) }
        Button("First") { action(.first) }
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

    private func unskippedTotal(_ node: FileNode) -> FileNode {
        node
    }
}

// MARK: - Node row

private struct NodeRow: View {
    let node: FileNode
    let depth: Int
    @Binding var expandedFolders: Set<String>
    var onToggle: (FileNode, Bool) -> Void
    var onPriorityChange: (String, FilePriority) -> Void

    private var selectionState: FileNode.SelectionState {
        FileTreeBuilder.selectionState(of: node)
    }

    var body: some View {
        HStack(spacing: 8) {
            checkbox
            Image(systemName: node.isFolder ? "folder.fill" : "doc")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text(node.name)
                .font(.callout)
                .strikethrough(node.priority == .skip && !node.isFolder)
                .foregroundStyle(node.priority == .skip && !node.isFolder ? Color.secondary : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !node.isFolder && node.priority != .normal {
                Text(node.priority.label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }
            Spacer(minLength: 8)
            Text(ByteFormatting.bytes(node.size))
                .font(.caption.tabularNumerics())
                .foregroundStyle(.secondary)

            priorityMenu
        }
        .padding(.leading, CGFloat(depth) * 16)
        .contentShape(Rectangle())
        .contextMenu {
            Button(node.priority == .skip ? "Include" : "Skip") {
                onToggle(node, node.priority == .skip)
            }
            Menu("Priority") {
                Button("Skip") { onPriorityChange(node.id, .skip) }
                Button("Normal") { onPriorityChange(node.id, .normal) }
                Button("High") { onPriorityChange(node.id, .high) }
                Button("First") { onPriorityChange(node.id, .first) }
            }
        }
    }

    private var checkbox: some View {
        Button {
            onToggle(node, selectionState == .none || selectionState == .partial)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .help(selectionState == .all ? "Deselect" : "Select")
        .accessibilityLabel(accessibilityDescription)
    }

    private var symbol: String {
        switch selectionState {
        case .all: return "checkmark.square.fill"
        case .partial: return "minus.square.fill"
        case .none: return "square"
        }
    }

    private var tint: Color {
        switch selectionState {
        case .all, .partial: return Color.accentColor
        case .none: return Color.secondary.opacity(0.4)
        }
    }

    private var accessibilityDescription: String {
        let state = selectionState == .all ? "Selected" : selectionState == .partial ? "Partially selected" : "Not selected"
        return "\(state): \(node.name)"
    }

    @ViewBuilder
    private var priorityMenu: some View {
        if !node.isFolder {
            Menu {
                Button("Skip") { onPriorityChange(node.id, .skip) }
                Button("Normal") { onPriorityChange(node.id, .normal) }
                Button("High") { onPriorityChange(node.id, .high) }
                Button("First") { onPriorityChange(node.id, .first) }
            } label: {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 20)
            .fixedSize()
            .help("Download priority")
        }
    }
}

// MARK: - Magnet file selection sheet

/// Full file picker opened from the notch card or the in-window overlay.
struct MagnetSelectionSheet: View {
    @EnvironmentObject private var app: AppEnvironment
    @EnvironmentObject private var flow: MagnetFlowCenter
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    let metadata: TorrentMetadata
    @State private var nodes: [FileNode]

    init(metadata: TorrentMetadata) {
        self.metadata = metadata
        _nodes = State(initialValue: FileTreeBuilder.build(from: metadata.files))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            FileTreeEditor(nodes: $nodes, showsFooterSummary: false)
            Divider()
            footerBar
        }
        .frame(width: 520, height: 480)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(metadata.displayName)
                .font(.headline)
                .lineLimit(1)
            Text("\(metadata.files.count) files · \(ByteFormatting.bytes(metadata.totalSize))")
                .font(.subheadline.tabularNumerics())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var selectedBytes: Int64 { FileTreeBuilder.selectedBytes(nodes) }

    private var footerBar: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                dismiss()
                Task { await app.cancelMagnetSelection() }
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button {
                let priorities = FileTreeBuilder.flattenPriorities(nodes)
                Task {
                    await app.applyMagnetSelection(priorities)
                    dismiss()
                }
            } label: {
                Text("Download \(ByteFormatting.bytes(selectedBytes))")
                    .tabularNumerics()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selectedBytes == 0)
        }
        .padding(14)
    }
}
