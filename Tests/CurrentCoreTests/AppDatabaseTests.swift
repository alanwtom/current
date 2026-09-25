import XCTest
import SQLite3
import CurrentCore
@testable import CurrentApp

final class AppDatabaseTests: XCTestCase {

    private func makeURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("current-db-\(UUID().uuidString).sqlite")
        addTeardownBlock {
            let manager = FileManager.default
            let folder = url.deletingLastPathComponent()
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            where name.hasPrefix(url.lastPathComponent) {
                try? manager.removeItem(at: folder.appendingPathComponent(name))
            }
        }
        return url
    }

    private func sampleSnapshot(id: TorrentID) -> TorrentSnapshot {
        TorrentSnapshot(
            id: id,
            name: "Sample Torrent",
            state: .seeding,
            progress: 1,
            totalBytes: 1_000,
            downloadedBytes: 1_000,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            saveDirectory: URL(fileURLWithPath: "/tmp/current-sample")
        )
    }

    /// Regression: opening an existing database must never truncate it.
    func testReopeningPreservesData() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let id = TorrentID("regression-id")
        do {
            let database = AppDatabase(url: url)
            try database.set("some-value", forKey: "some-key")
            try database.upsertTorrent(sampleSnapshot(id: id), policy: .helpful, pinned: true)
        }

        let reopened = AppDatabase(url: url)
        XCTAssertEqual(reopened.allSettings()["some-key"], "some-value")

        let records = reopened.loadTorrentRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.id, id)
        XCTAssertEqual(records.first?.pinned, true)
        XCTAssertEqual(records.first?.directory.absoluteString, "file:///tmp/current-sample")
    }

    func testFreshDatabaseStartsEmpty() {
        let database = AppDatabase(url: makeURL())
        XCTAssertTrue(database.allSettings().isEmpty)
        XCTAssertTrue(database.loadTorrentRecords().isEmpty)
        XCTAssertTrue(database.allResumeData().isEmpty)
    }

    func testResumeDataRoundTrip() throws {
        let url = makeURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let database = AppDatabase(url: url)
        let id = TorrentID("resume-id")
        let blob = Data("resume-bytes".utf8)
        try database.storeResumeData(blob, for: id)

        let reopened = AppDatabase(url: url)
        XCTAssertEqual(reopened.allResumeData().first?.id, id)
        XCTAssertEqual(reopened.allResumeData().first?.data, blob)
    }

    /// A damaged file is set aside and replaced, and the app is told. It used
    /// to open "successfully", read back nothing, and let every setting —
    /// the VPN binding included — fall silently to its default.
    func testAnUnreadableFileIsKeptAsideAndReplaced() throws {
        let url = makeURL()
        try Data(repeating: 0xAB, count: 8192).write(to: url)

        let database = AppDatabase(url: url)
        XCTAssertTrue(database.recoveredFromUnreadableFile)
        try database.set("1", forKey: "probe")
        XCTAssertEqual(database.allSettings()["probe"], "1", "the fresh database must work")

        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(
            siblings.contains { $0.hasPrefix(url.lastPathComponent + ".unreadable-") },
            "the damaged file must be kept, not deleted"
        )
    }

    func testAHealthyFileIsNotTreatedAsRecovered() throws {
        let url = makeURL()
        try AppDatabase(url: url).set("kept", forKey: "k")
        let reopened = AppDatabase(url: url)
        XCTAssertFalse(reopened.recoveredFromUnreadableFile)
        XCTAssertEqual(reopened.allSettings()["k"], "kept")
    }

    /// Busy is not broken. The installed app and a dev build open the same
    /// library, and a file that is merely locked by the other one must be
    /// left exactly where it is — setting it aside would be the app losing the
    /// user's library to a timing accident.
    func testALockedFileIsNotMistakenForADamagedOne() throws {
        let url = makeURL()
        var other: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &other), SQLITE_OK)
        defer { sqlite3_close(other) }
        sqlite3_exec(other, "CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);", nil, nil, nil)
        XCTAssertEqual(sqlite3_exec(other, "BEGIN EXCLUSIVE;", nil, nil, nil), SQLITE_OK)

        let database = AppDatabase(url: url)

        XCTAssertFalse(database.recoveredFromUnreadableFile)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(url.lastPathComponent + ".unreadable-") })
        sqlite3_exec(other, "COMMIT;", nil, nil, nil)
    }
}
