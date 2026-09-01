import XCTest
import CurrentCore
@testable import CurrentApp

final class AppDatabaseTests: XCTestCase {

    private func makeURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("current-db-\(UUID().uuidString).sqlite")
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
}
