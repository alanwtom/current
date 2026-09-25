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
    func trashContent(id: TorrentID, saveDirectory: URL, files: [FileInfo]) -> Int {
        let manager = FileManager.default
        let root = ContentLocation.rootFolder(saveDirectory: saveDirectory, files: files)
        let plan = ContentLocation.trashPlan(
            saveDirectory: saveDirectory,
            files: files,
            rootListing: root.flatMap { listing(of: $0, relativeTo: saveDirectory) },
            partFile: ".\(id.raw).parts"
        )

        let partFile = saveDirectory.standardizedFileURL.appendingPathComponent(".\(id.raw).parts")
        var moved = 0
        for step in plan {
            switch step {
            case .item(let url):
                // `attributesOfItem` rather than `fileExists`: it doesn't
                // follow a symlink, so a link is judged — and trashed — as the
                // link, never as whatever it points at.
                guard (try? manager.attributesOfItem(atPath: url.path)) != nil else { continue }
                if (try? moveToTrash(url)) != nil, url != partFile { moved += 1 }
            case .folderIfEmpty(let url):
                guard let contents = try? manager.contentsOfDirectory(atPath: url.path),
                      contents.allSatisfy(ContentLocation.incidentalNames.contains)
                else { continue }
                if (try? moveToTrash(url)) != nil { moved += 1 }
            }
        }
        return moved
    }

    /// Every file and link under `root`, relative to `base`. Doesn't descend
    /// into symlinked folders — a link is one entry, like a file.
    private func listing(of root: URL, relativeTo base: URL) -> [String]? {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
              )
        else { return nil }

        let prefix = base.standardizedFileURL.path + "/"
        let rootName = root.lastPathComponent
        let rootPath = root.standardizedFileURL.path
        var entries: [String] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isDirectory == true && values?.isSymbolicLink != true { continue }
            let path = url.standardizedFileURL.path
            // Rebuilt from the root's own spelling, so a case-insensitive match
            // on the root folder still compares inner paths as they are on disk.
            guard path.hasPrefix(rootPath + "/") else {
                guard path.hasPrefix(prefix) else { continue }
                entries.append(String(path.dropFirst(prefix.count)))
                continue
            }
            entries.append(rootName + "/" + path.dropFirst(rootPath.count + 1))
        }
        return entries
    }
}
