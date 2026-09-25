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
            rootListing: root.flatMap(listing(of:)),
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
                guard let type = (try? manager.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
                else { continue }
                // The root is always a folder and nothing else of the
                // torrent's ever is. A folder where one of its files should be
                // — or a file where its folder should be — belongs to someone
                // else: another torrent that unpacked there first, or the user.
                guard (type == .typeDirectory) == (url == root) else { continue }
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

    /// Every file and link under `root`, as paths relative to the save folder
    /// (`"Root/sub/a.mkv"`) — or nil when that can't be said for certain:
    /// `root` isn't a real folder, or some part of it couldn't be read. Nil
    /// makes the plan take the torrent's files one by one rather than the
    /// folder whole, which is always safe.
    ///
    /// Each path is built from the names the folder itself hands back, never
    /// by comparing path strings with the save folder's. The version this
    /// replaced asked the directory enumerator for URLs and matched them
    /// against the save folder's spelling — but the enumerator returns paths
    /// with symlinks resolved, so a save folder reached through a link
    /// (~/Downloads moved to an external drive) matched nothing. Every entry
    /// was skipped, the empty result read as "nothing here but ours", and the
    /// whole folder went to the Trash with other people's files in it. The
    /// enumerator also skipped unreadable folders without saying so, which
    /// failed open the same way.
    ///
    /// Doesn't descend into symlinked folders — a link is one entry, like a
    /// file. The root takes the torrent's own spelling, so a case-insensitive
    /// match on it still compares inner paths as they are on disk.
    private func listing(of root: URL) -> [String]? {
        let manager = FileManager.default
        func type(at path: String) -> FileAttributeType? {
            (try? manager.attributesOfItem(atPath: path))?[.type] as? FileAttributeType
        }
        var entries: [String] = []
        func walk(_ folder: String, as relative: String) -> Bool {
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { return false }
            for name in names {
                let path = folder + "/" + name
                guard let kind = type(at: path) else { return false }
                if kind == .typeDirectory {
                    guard walk(path, as: relative + "/" + name) else { return false }
                } else {
                    entries.append(relative + "/" + name)
                }
            }
            return true
        }
        guard type(at: root.path) == .typeDirectory,
              walk(root.path, as: root.lastPathComponent)
        else { return nil }
        return entries
    }
}
