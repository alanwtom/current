import Foundation

/// Where a torrent's files sit on disk, for the one operation that must never
/// be wrong about it: moving them to the Trash.
///
/// **A torrent owns its files, not its name.** Deleting used to trash
/// `saveDirectory/name` — whatever happened to be there — and two things went
/// wrong with that:
///
/// 1. The target was built twice, once with `appendingPathExtension` where
///    `appendingPathComponent` was meant. Foundation returns the URL
///    *unchanged* for an extension it won't accept — a name ending in a full
///    stop, an empty name, one with a slash — so for those names the second
///    candidate was the download folder itself. It always exists, so it always
///    matched. A torrent named `Something.` that never downloaded a byte, one
///    "Remove and delete files", and the whole download folder went to the
///    Trash. A .torrent file sets that name, and so did a magnet's `dn=` under
///    the simulator.
/// 2. Even spelled right, the name is only where the torrent *would* put its
///    files. A torrent called `Documents` with the save folder set to the home
///    folder "owned" the user's own Documents, every unrelated file in it
///    included; two torrents that both unpack into `Season 1` deleted each
///    other.
///
/// So the plan is built from the torrent's own file list, every path is proved
/// to sit inside the save folder before it can be named, and a folder is taken
/// whole only when everything in it belongs to the torrent. No metadata means
/// the torrent never wrote anything, and nothing is touched.
public enum ContentLocation {

    // MARK: - The files a torrent owns

    /// One step of moving a torrent's content to the Trash.
    public enum TrashStep: Equatable, Sendable {
        /// Move this to the Trash if it exists.
        case item(URL)
        /// Move this folder to the Trash only if nothing is left in it — it
        /// held the torrent's files, but it may hold other things too.
        case folderIfEmpty(URL)
    }

    /// Names Finder leaves in any folder it has shown. Their presence doesn't
    /// make a folder anyone's but the torrent's.
    public static let incidentalNames: Set<String> = [".DS_Store"]

    /// Whether one path component is safe to put under a directory.
    static func isSafeComponent(_ component: String) -> Bool {
        !component.isEmpty && component != "." && component != ".."
            && !component.contains("/") && !component.contains("\0")
    }

    /// Each file as a URL under the save folder, or nil if any one of them
    /// can't be proved to stay inside it. One bad path refuses the lot: a file
    /// list that tries to leave the folder is not one to act on at all.
    public static func ownedFiles(saveDirectory: URL, files: [FileInfo]) -> [URL]? {
        let base = saveDirectory.standardizedFileURL
        var result: [URL] = []
        result.reserveCapacity(files.count)
        for file in files {
            guard !file.pathComponents.isEmpty,
                  file.pathComponents.allSatisfy(isSafeComponent)
            else { return nil }
            let url = file.pathComponents
                .reduce(base) { $0.appendingPathComponent($1) }
                .standardizedFileURL
            guard url.path.hasPrefix(base.path + "/") else { return nil }
            result.append(url)
        }
        return result
    }

    /// The folder a multi-file torrent keeps everything in, or nil for a
    /// single file. libtorrent lays a multi-file torrent out as
    /// `name/…`, so every path shares a first component.
    public static func rootFolder(saveDirectory: URL, files: [FileInfo]) -> URL? {
        guard let first = files.first?.pathComponents.first,
              files.allSatisfy({ $0.pathComponents.count >= 2 && $0.pathComponents.first == first }),
              isSafeComponent(first)
        else { return nil }
        return saveDirectory.standardizedFileURL.appendingPathComponent(first, isDirectory: true)
    }

    /// What to move to the Trash for one torrent.
    ///
    /// - Parameters:
    ///   - files: the torrent's file list; empty when it has no metadata.
    ///   - rootListing: every file and link found under the root folder, as
    ///     paths relative to the save folder (`"Root/sub/a.mkv"`), or nil when
    ///     there is no root folder on disk. Directories are not listed.
    ///   - partFile: libtorrent's `.<hash>.parts` beside the content, which
    ///     holds the edges of pieces from skipped files. It is the torrent's.
    public static func trashPlan(
        saveDirectory: URL,
        files: [FileInfo],
        rootListing: [String]?,
        partFile: String? = nil
    ) -> [TrashStep] {
        guard !files.isEmpty,
              let owned = ownedFiles(saveDirectory: saveDirectory, files: files)
        else { return [] }

        let base = saveDirectory.standardizedFileURL
        var steps: [TrashStep] = []
        if let partFile, isSafeComponent(partFile) {
            steps.append(.item(base.appendingPathComponent(partFile)))
        }

        guard let root = rootFolder(saveDirectory: saveDirectory, files: files) else {
            // A single file is its own content.
            return steps + owned.map(TrashStep.item)
        }

        let ownedRelative = Set(files.map { $0.pathComponents.joined(separator: "/") })
        let onlyOurs = rootListing?.allSatisfy { entry in
            ownedRelative.contains(entry)
                || incidentalNames.contains((entry as NSString).lastPathComponent)
        } ?? true
        if onlyOurs {
            // Everything in there is the torrent's, so the folder goes whole —
            // one item in the Trash, and Put Back restores it in one go.
            return steps + [.item(root)]
        }

        // Something in the folder isn't the torrent's. Take only what is, and
        // then whichever of its folders that leaves empty, deepest first.
        var folders = Set<URL>()
        for file in files {
            var components = Array(file.pathComponents.dropLast())
            while !components.isEmpty {
                folders.insert(components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) })
                components.removeLast()
            }
        }
        let deepestFirst = folders.sorted { $0.pathComponents.count > $1.pathComponents.count }
        return steps + owned.map(TrashStep.item) + deepestFirst.map(TrashStep.folderIfEmpty)
    }

    /// The key two torrents collide on when they would share content: the
    /// same first path component in the same folder, compared the way the
    /// default Mac file system does — ignoring case.
    public static func contentKey(saveDirectory: URL, files: [FileInfo], name: String) -> String {
        let first = files.first?.pathComponents.first ?? name
        return saveDirectory.standardizedFileURL
            .appendingPathComponent(first).path
            .precomposedStringWithCanonicalMapping
            .lowercased()
    }
}
