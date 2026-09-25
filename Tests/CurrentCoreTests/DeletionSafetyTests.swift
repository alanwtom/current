import XCTest
import CurrentCore
import CurrentSim
@testable import CurrentApp

/// "Remove and delete files" must move exactly the torrent's own files to the
/// Trash — never its neighbours, never the folder it sits in.
///
/// These run against real folders in a scratch directory, with the Trash
/// replaced by a recorder, because every one of the ways this went wrong was a
/// disagreement between a path string and what was actually on disk.
@MainActor
final class DeletionSafetyTests: XCTestCase {

    private var save: URL!
    private var trash: TrashRecorder!
    private var store: LibraryStore!

    override func setUp() async throws {
        save = try makeScratchDirectory(self, "save")
        trash = TrashRecorder()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-delete-\(UUID().uuidString).sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        store = LibraryStore(engine: RecordingEngine(), database: AppDatabase(url: url), persistsRecords: false)
        store.contentTrash.moveToTrash = trash.move
    }

    // MARK: - Fixtures

    private func write(_ relative: String, _ text: String = "x") throws {
        let url = save.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: save.appendingPathComponent(relative).path)
    }

    /// A torrent in the library. `files: nil` is a torrent with no metadata.
    private func add(_ id: String, name: String, files: [[String]]?) {
        store.applySnapshots([TorrentSnapshot(
            id: TorrentID(id), name: name, state: .seeding, progress: 1,
            totalBytes: 1, downloadedBytes: 1, saveDirectory: save, hasMetadata: files != nil
        )])
        if let files {
            store.applyMetadata(TorrentMetadata(
                id: TorrentID(id), displayName: name, totalSize: 1, pieceCount: 1, pieceLength: 16_384,
                files: files.map { FileInfo(pathComponents: $0, size: 1) }
            ))
        }
    }

    private func deleteWithFiles(_ id: String) async {
        await store.remove([TorrentID(id)], deleteFiles: true)
    }

    // MARK: - The shipped bug

    /// **1.2.0.** A name Foundation won't take as a path extension — a
    /// trailing full stop is enough — made the second candidate path the save
    /// folder itself. With the torrent's own content absent (it never
    /// downloaded), that was the one that existed, and it went to the Trash.
    func testANameEndingInAFullStopNeverTakesTheFolder() async throws {
        try write("someone else's film.mkv")
        add("a", name: "Wait for it.", files: [["Wait for it."]])

        await deleteWithFiles("a")

        XCTAssertEqual(trash.urls, [], "nothing of the torrent's was on disk, so nothing moves")
        XCTAssertTrue(exists("someone else's film.mkv"))
    }

    /// Hostile names, with no metadata behind them — a magnet that never
    /// resolved. Such a torrent never wrote a byte, and must delete none.
    func testATorrentWithoutMetadataDeletesNothingWhateverItsName() async throws {
        try write("keep.txt")
        try write("Photos/holiday.jpg")
        for (index, name) in ["..", "", ".", "Photos", "../../", "x.", "a/b"].enumerated() {
            add("m\(index)", name: name, files: nil)
            await deleteWithFiles("m\(index)")
        }
        XCTAssertEqual(trash.urls, [])
        XCTAssertTrue(exists("keep.txt"))
        XCTAssertTrue(exists("Photos/holiday.jpg"))
    }

    // MARK: - Owning files, not names

    func testASingleFileTorrentTakesItsFile() async throws {
        try write("film.mkv")
        try write("other.mkv")
        add("a", name: "film.mkv", files: [["film.mkv"]])

        await deleteWithFiles("a")

        XCTAssertEqual(trash.urls.map(\.lastPathComponent), ["film.mkv"])
        XCTAssertTrue(exists("other.mkv"))
    }

    /// Everything in the folder is the torrent's, so the folder goes whole —
    /// one Trash item, one Put Back. Finder's `.DS_Store` doesn't count
    /// against it.
    func testAFolderHoldingOnlyTheTorrentGoesWhole() async throws {
        try write("Show/e1.mkv")
        try write("Show/sub/e1.srt")
        try write("Show/.DS_Store")
        add("a", name: "Show", files: [["Show", "e1.mkv"], ["Show", "sub", "e1.srt"]])

        await deleteWithFiles("a")

        XCTAssertEqual(trash.urls.map(\.lastPathComponent), ["Show"])
        XCTAssertFalse(exists("Show"))
    }

    /// The case that made "the name" the wrong thing to own: a folder that
    /// was already there. Only the torrent's files leave; the user's stay.
    func testAFolderThatAlsoHoldsSomeoneElsesFilesKeepsThem() async throws {
        try write("Documents/tax return.pdf", "mine")
        try write("Documents/readme.txt")
        add("a", name: "Documents", files: [["Documents", "readme.txt"]])

        await deleteWithFiles("a")

        XCTAssertEqual(trash.urls.map(\.lastPathComponent), ["readme.txt"])
        XCTAssertTrue(exists("Documents/tax return.pdf"))
    }

    /// Two torrents unpacking into one folder: deleting one leaves the other.
    func testTwoTorrentsSharingAFolderDoNotDeleteEachOther() async throws {
        try write("Season 1/e1.mkv")
        try write("Season 1/e2.mkv")
        add("one", name: "Season 1", files: [["Season 1", "e1.mkv"]])
        add("two", name: "Season 1", files: [["Season 1", "e2.mkv"]])

        await deleteWithFiles("one")

        XCTAssertTrue(exists("Season 1/e2.mkv"))
        XCTAssertFalse(exists("Season 1/e1.mkv"))
    }

    /// Folders the torrent created are tidied away once empty — and one that
    /// still holds something is left exactly where it was.
    func testFoldersEmptiedByTheDeleteGoTooButOnlyWhenEmpty() async throws {
        try write("Pack/a/one.bin")
        try write("Pack/b/two.bin")
        try write("Pack/b/mine.txt")
        add("a", name: "Pack", files: [["Pack", "a", "one.bin"], ["Pack", "b", "two.bin"]])

        await deleteWithFiles("a")

        XCTAssertFalse(exists("Pack/a"))
        XCTAssertTrue(exists("Pack/b/mine.txt"))
        XCTAssertFalse(exists("Pack/b/two.bin"))
    }

    /// A link is trashed as a link. Following it would put whatever it points
    /// at — possibly far outside the download folder — in the Trash.
    func testASymlinkIsTakenAsItselfNotItsTarget() async throws {
        let outside = try makeScratchDirectory(self, "outside")
        let precious = outside.appendingPathComponent("precious.txt")
        try Data("keep".utf8).write(to: precious)
        try FileManager.default.createSymbolicLink(
            at: save.appendingPathComponent("link"), withDestinationURL: precious
        )
        add("a", name: "link", files: [["link"]])

        await deleteWithFiles("a")

        XCTAssertEqual(trash.urls.map(\.lastPathComponent), ["link"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
    }

    /// libtorrent keeps the edges of skipped files in `.<hash>.parts` beside
    /// the content. It's the torrent's, and would otherwise be left behind.
    func testThePartFileGoesWithTheTorrent() async throws {
        try write("film.mkv")
        try write(".a.parts")
        add("a", name: "film.mkv", files: [["film.mkv"]])

        await deleteWithFiles("a")

        XCTAssertEqual(Set(trash.urls.map(\.lastPathComponent)), ["film.mkv", ".a.parts"])
    }

    // MARK: - The plan itself

    func testAFileListThatTriesToLeaveIsRefusedWhole() {
        for hostile: [[String]] in [[["..", "etc"]], [["ok"], ["a", "..", "..", "b"]], [[""]], [["a/b"]], [[]]] {
            let plan = ContentLocation.trashPlan(
                saveDirectory: save,
                files: hostile.map { FileInfo(pathComponents: $0, size: 1) },
                rootListing: nil
            )
            XCTAssertEqual(plan, [], "\(hostile)")
        }
    }

    func testNothingInThePlanIsOutsideTheSaveFolderOrIsIt() {
        let files = [["Root", "a"], ["Root", "b", "c"]].map { FileInfo(pathComponents: $0, size: 1) }
        let plan = ContentLocation.trashPlan(
            saveDirectory: save, files: files, rootListing: ["Root/a", "Root/b/c", "Root/foreign"], partFile: ".h.parts"
        )
        XCTAssertFalse(plan.isEmpty)
        for step in plan {
            let url: URL
            switch step {
            case .item(let u), .folderIfEmpty(let u): url = u
            }
            XCTAssertTrue(url.standardizedFileURL.path.hasPrefix(save.path + "/"), "\(url.path)")
            XCTAssertNotEqual(url.standardizedFileURL.path, save.path)
        }
    }

    // MARK: - Where downloads may go

    func testFoldersWhereAFileNameAloneDoesHarmCantBeChosen() {
        let home = URL(fileURLWithPath: "/Users/someone")
        for refused in ["/", "/Users", "/Users/someone", "/Users/someone/", "/Users/someone/Library",
                        "/Users/someone/Library/LaunchAgents", "/Applications", "/System/Library",
                        "/usr/local", "/Users/someone/Downloads/../"] {
            XCTAssertNotNil(SaveLocation.refusal(for: URL(fileURLWithPath: refused), home: home), refused)
        }
        for allowed in ["/Users/someone/Downloads", "/Users/someone/Downloads/Current",
                        "/Volumes/External/Torrents", "/Users/someone/Library Stuff",
                        "/Users/someone/Movies/Library"] {
            XCTAssertNil(SaveLocation.refusal(for: URL(fileURLWithPath: allowed), home: home), allowed)
        }
    }
}
