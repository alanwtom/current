import Foundation
import CurrentCore

/// Moves a torrent's own files to the Trash, and nothing else.
///
/// The plan is `ContentLocation.trashPlan`, which is pure and tested; this is
/// the part that looks at the disk and acts on it. Both deletes go through
/// here — the user's "Remove and delete files" and automatic cleanup — because
/// the two used to build their paths separately, and when one was fixed the
/// other kept the bug.
struct ContentTrash {
    struct Result: Equatable {
        var movedItems: Int
        var expectedItems: Int
        var isComplete: Bool { expectedItems > 0 && movedItems == expectedItems }
    }

    /// The move itself. Replaced in tests, which have no business putting
    /// files in the real Trash.
    var moveToTrash: (URL) throws -> Void = { url in
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// Returns how many of the torrent's content items went to the Trash. Zero
    /// means none did — nothing of it was on disk, or its file list couldn't be
    /// trusted — and callers must not report space as reclaimed. libtorrent's
    /// part file goes too, but isn't counted: it alone reclaims nothing.
    @discardableResult
    func trashContent(id: TorrentID, saveDirectory: URL, files: [FileInfo]) -> Result {
        // Resolve aliases above the chosen folder (including macOS /var).
        // Keep the final component unresolved so a replaced save folder is refused.
        let requested = saveDirectory.standardizedFileURL
        let base = requested.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(requested.lastPathComponent, isDirectory: true)
        guard let owned = ContentLocation.ownedFiles(saveDirectory: base, files: files),
              !owned.isEmpty, safeAncestors(of: base, through: base),
              owned.allSatisfy({ !isDirectory($0) })
        else { return Result(movedItems: 0, expectedItems: 0) }
        let root = ContentLocation.rootFolder(saveDirectory: base, files: files)
        let partFile = base.appendingPathComponent(".\(id.raw).parts")
        let proposed = ContentLocation.trashPlan(
            saveDirectory: base, files: files,
            rootListing: root.flatMap { listing(of: $0, relativeTo: base) },
            partFile: partFile.lastPathComponent
        )
        guard let plan = safePlan(proposed, base: base) else {
            return Result(movedItems: 0, expectedItems: 0)
        }
        var result = Result(movedItems: 0, expectedItems: 0)
        for step in plan {
            apply(step, base: base, partFile: partFile, result: &result)
        }
        return result
    }

    private func apply(_ step: ContentLocation.TrashStep, base: URL, partFile: URL, result: inout Result) {
        switch step {
        case .item(let url):
            if url != partFile { result.expectedItems += 1 }
            guard safeAncestors(of: base, through: url.deletingLastPathComponent()),
                  (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil else { return }
            if (try? moveToTrash(url)) != nil, url != partFile { result.movedItems += 1 }
        case .folderIfEmpty(let url):
            guard safeAncestors(of: base, through: url),
                  let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
                  contents.allSatisfy(ContentLocation.incidentalNames.contains) else { return }
            // Empty parent folders are housekeeping, not downloaded content.
            try? moveToTrash(url)
        }
    }

    /// Every file and link under `root`, relative to `base`. Doesn't descend
    /// into symlinked folders — a link is one entry, like a file.
    private func listing(of root: URL, relativeTo base: URL) -> [String]? {
        guard safeAncestors(of: base.standardizedFileURL, through: root.deletingLastPathComponent()),
              !isSymbolicLink(root), isDirectory(root) else { return nil }
        return walk(root, prefix: root.lastPathComponent)
    }

    private func walk(_ directory: URL, prefix: String) -> [String]? {
        guard let children = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        var entries: [String] = []
        for child in children {
            guard safeAncestors(of: directory, through: directory), let attributes = try? FileManager.default.attributesOfItem(atPath: child.path) else {
                return nil
            }
            let relative = prefix + "/" + child.lastPathComponent
            if attributes[.type] as? FileAttributeType == .typeDirectory {
                guard let nested = walk(child, prefix: relative) else { return nil }
                entries.append(contentsOf: nested)
                if nested.isEmpty { entries.append(relative + "/") }
            } else {
                entries.append(relative)
            }
        }
        return entries
    }

    private func safePlan(_ plan: [ContentLocation.TrashStep], base: URL) -> [ContentLocation.TrashStep]? {
        guard safeAncestors(of: base, through: base) else { return nil }
        for step in plan {
            let url: URL
            switch step {
            case .item(let item): url = item
            case .folderIfEmpty(let folder): url = folder
            }
            guard url.standardizedFileURL.path.hasPrefix(base.path + "/") else { return nil }
        }
        return plan
    }

    /// Every component above the final item must be a real directory. A final
    /// item may be a symlink because moving the link itself is safe.
    private func safeAncestors(of base: URL, through target: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let targetPath = target.standardizedFileURL.path
        guard targetPath == basePath || targetPath.hasPrefix(basePath + "/") else { return false }
        // The chosen save folder is the boundary. macOS itself uses links
        // above it (/var and /tmp); only links at or below it can redirect a
        // torrent's metadata path outside that boundary.
        var current = URL(fileURLWithPath: basePath)
        guard isDirectory(current), !isSymbolicLink(current) else { return false }
        let suffix = targetPath == basePath ? [] : targetPath.dropFirst(basePath.count + 1).split(separator: "/").map(String.init)
        for component in suffix {
            current.appendPathComponent(component)
            guard isDirectory(current), !isSymbolicLink(current) else { return false }
        }
        return true
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
