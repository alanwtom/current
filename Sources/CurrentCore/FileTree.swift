import Foundation

/// A node in the hierarchical file view of a torrent.
///
/// Built from the flat file list so folders exist only where real folders
/// exist. Selection state is tri-state because folders aggregate their
/// children.
public struct FileNode: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case file(engineIndex: Int)
        case folder
    }

    public enum SelectionState: Equatable, Sendable {
        case none
        case partial
        case all

        var checkboxValue: Int {
            switch self {
            case .none: return 0
            case .partial: return 1
            case .all: return 2
            }
        }
    }

    public var id: String
    public var name: String
    public var kind: Kind
    public var size: Int64
    public var children: [FileNode]
    /// Only meaningful for files; folders derive priority from children.
    public var priority: FilePriority

    public init(id: String, name: String, kind: Kind, size: Int64, children: [FileNode], priority: FilePriority = .normal) {
        self.id = id
        self.name = name
        self.kind = kind
        self.size = size
        self.children = children
        self.priority = priority
    }

    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }
}

public enum FileTreeBuilder {

    /// Builds a tree from flat engine indices. `priorities` must align with
    /// `files` by index; missing entries default to `.normal`.
    public static func build(
        from files: [FileInfo],
        priorities: [FilePriority] = []
    ) -> [FileNode] {
        var rootChildren: [String: FileNode] = [:]

        for (index, info) in files.enumerated() {
            let priority = index < priorities.count ? priorities[index] : .normal
            insert(
                components: info.pathComponents,
                size: info.size,
                engineIndex: index,
                priority: priority,
                into: &rootChildren,
                parentID: "root"
            )
        }

        let nodes = rootChildren.values.map(normalize)
        return nodes.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func insert(
        components: [String],
        size: Int64,
        engineIndex: Int,
        priority: FilePriority,
        into container: inout [String: FileNode],
        parentID: String
    ) {
        guard let head = components.first else { return }
        let id = parentID + "/" + head
        let remaining = Array(components.dropFirst())

        if remaining.isEmpty {
            container[id] = FileNode(
                id: id,
                name: head,
                kind: .file(engineIndex: engineIndex),
                size: size,
                children: [],
                priority: priority
            )
        } else {
            var existing = container[id] ?? FileNode(
                id: id, name: head, kind: .folder, size: 0, children: []
            )
            var childMap = Dictionary(existing.children.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            insert(
                components: remaining,
                size: size,
                engineIndex: engineIndex,
                priority: priority,
                into: &childMap,
                parentID: id
            )
            existing.children = childMap.values.map(normalize).sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            existing.size = totalSize(existing.children)
            existing.priority = aggregatePriority(existing.children)
            container[id] = existing
        }
    }

    private static func normalize(_ node: FileNode) -> FileNode {
        guard node.isFolder else { return node }
        var copy = node
        copy.size = totalSize(node.children)
        copy.priority = aggregatePriority(node.children)
        return copy
    }

    private static func totalSize(_ nodes: [FileNode]) -> Int64 {
        nodes.reduce(0) { $0 + $1.size }
    }

    private static func aggregatePriority(_ nodes: [FileNode]) -> FilePriority {
        let values = nodes.map(\.priority.rawValue)
        if values.allSatisfy({ $0 == 0 }) { return .skip }
        let maxPriority = values.max() ?? 4
        return FilePriority(rawValue: maxPriority)
    }

    // MARK: - Selection

    /// Applies a selection to every descendant of `node`, returning the new tree.
    public static func setSelection(_ nodes: [FileNode], id: String, selected: Bool) -> [FileNode] {
        nodes.map { node in
            var updated = node
            if updated.id == id {
                updated = applySelection(updated, selected: selected)
            } else if updated.isFolder && !updated.children.isEmpty {
                updated.children = setSelection(updated.children, id: id, selected: selected)
                updated.priority = aggregatePriority(updated.children)
            }
            return updated
        }
    }

    private static func applySelection(_ node: FileNode, selected: Bool) -> FileNode {
        var copy = node
        let priority = selected ? FilePriority.normal : .skip
        copy.priority = priority
        for index in copy.children.indices {
            copy.children[index] = applySelection(copy.children[index], selected: selected)
        }
        if !copy.children.isEmpty {
            copy.priority = aggregatePriority(copy.children)
        }
        return copy
    }

    public static func selectionState(of node: FileNode) -> FileNode.SelectionState {
        if !node.isFolder {
            return node.priority == .skip ? .none : .all
        }
        let states = node.children.map(selectionState(of:))
        if states.allSatisfy({ $0 == .all }) { return .all }
        if states.allSatisfy({ $0 == .none }) { return .none }
        return .partial
    }

    public static func selectedBytes(_ nodes: [FileNode]) -> Int64 {
        nodes.reduce(0) { sum, node in
            if node.isFolder {
                return sum + selectedBytes(node.children)
            }
            return sum + (node.priority == .skip ? 0 : node.size)
        }
    }

    public static func leafCount(_ nodes: [FileNode]) -> Int {
        nodes.reduce(0) { count, node in
            node.isFolder ? count + leafCount(node.children) : count + 1
        }
    }

    /// Flattens to per-engine-index priorities aligned with the original list.
    public static func flattenPriorities(_ nodes: [FileNode]) -> [FilePriority] {
        var result: [FilePriority] = []
        walk(nodes) { node in
            if case .file(let index) = node.kind {
                while result.count <= index { result.append(.normal) }
                result[index] = node.priority
            }
        }
        return result
    }

    public static func walk(_ nodes: [FileNode], _ visitor: (FileNode) -> Void) {
        for node in nodes {
            visitor(node)
            if node.isFolder { walk(node.children, visitor) }
        }
    }

    /// Filters leaves whose name matches the query, keeping ancestor folders.
    public static func filtered(_ nodes: [FileNode], query: String) -> [FileNode] {
        guard !query.isEmpty else { return nodes }
        let lowered = query.lowercased()
        return nodes.compactMap { node -> FileNode? in
            if !node.isFolder {
                return node.name.lowercased().contains(lowered) ? node : nil
            }
            let children = filtered(node.children, query: query)
            if children.isEmpty {
                return node.name.lowercased().contains(lowered) ? node : nil
            }
            var copy = node
            copy.children = children
            copy.size = totalSize(children)
            copy.priority = aggregatePriority(children)
            return copy
        }
    }
}
