import Foundation
import SQLite3
import CurrentCore

/// Minimal, dependency-free persistence for app-level state: settings,
/// per-torrent records (pinning, policies), decision history, cleanup events,
/// and engine resume data.
final class AppDatabase: Sendable {

    private struct State {
        var handle: OpaquePointer?
    }

    private let lock = NSLock()
    private nonisolated(unsafe) var handle: OpaquePointer?

    private static let schema = """
        CREATE TABLE IF NOT EXISTS settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS torrents (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            pinned INTEGER NOT NULL DEFAULT 0,
            policy TEXT NOT NULL DEFAULT 'balanced',
            added_at REAL NOT NULL,
            save_directory TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS resume_data (
            id TEXT PRIMARY KEY,
            blob BLOB NOT NULL
        );
        CREATE TABLE IF NOT EXISTS decisions (
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            torrent_id TEXT,
            torrent_name TEXT,
            date REAL NOT NULL,
            reasons TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS decisions_date ON decisions(date DESC);
        """

    /// True when the file on disk couldn't be read and a fresh one was
    /// started in its place. The old file is kept beside it, renamed.
    ///
    /// This used to be invisible. `sqlite3_open` succeeds on a damaged file,
    /// the schema step failed into a log line, and every read afterwards came
    /// back empty — so every setting silently fell back to its default. For
    /// the VPN binding that default is "any connection": someone who had
    /// confined transfers to their tunnel was transferring over their real
    /// address with nothing on screen to say so.
    let recoveredFromUnreadableFile: Bool

    init(url: URL) {
        // sqlite3_open creates the file when missing; never truncate an
        // existing library — it holds settings, records and resume data.
        switch Self.open(url) {
        case .ready(let db):
            handle = db
            recoveredFromUnreadableFile = false
        case .unusable(let db):
            // Something other than damage — busy, permissions, a full disk.
            // Carry on with whatever opened, exactly as before; moving a file
            // aside is only for a file SQLite has said is not a database.
            handle = db
            recoveredFromUnreadableFile = false
        case .damaged:
            // Keep it — it is the user's data, and a later version might read
            // it — and start a fresh one where it was.
            let stamp = Int(Date().timeIntervalSince1970)
            for suffix in ["", "-wal", "-shm"] {
                let from = URL(fileURLWithPath: url.path + suffix)
                let to = URL(fileURLWithPath: url.path + ".unreadable-\(stamp)" + suffix)
                try? FileManager.default.moveItem(at: from, to: to)
            }
            if case .ready(let db) = Self.open(url) { handle = db }
            recoveredFromUnreadableFile = true
            NSLog("Current: library database was unreadable; started a fresh one")
        }
    }

    private enum Opened {
        case ready(OpaquePointer)
        /// SQLite said, definitively, that this is not a usable database.
        case damaged
        case unusable(OpaquePointer?)
    }

    /// The two answers that mean the file itself is bad. Anything else —
    /// `BUSY` above all, since a dev build and the installed app can have the
    /// same library open — is not a reason to touch the file.
    private static func isDamage(_ code: Int32) -> Bool {
        let primary = code & 0xFF
        return primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT
    }

    private static func open(_ url: URL) -> Opened {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return .unusable(nil)
        }
        // Another process holding the file is normal; wait for it rather than
        // failing the first statement.
        sqlite3_busy_timeout(db, 2_000)
        // WAL with NORMAL sync is the combination SQLite recommends: durable
        // against a crash of this app, and one fsync per checkpoint rather
        // than one per write. At launch a restored library writes a record
        // per torrent, and FULL made each of those a disk flush on the main
        // thread.
        sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)

        let schema = sqlite3_exec(db, Self.schema, nil, nil, nil)
        if schema != SQLITE_OK {
            NSLog("Current database schema error: \(String(cString: sqlite3_errmsg(db)))")
            if isDamage(schema) {
                sqlite3_close(db)
                return .damaged
            }
            return .unusable(db)
        }
        switch quickCheck(db) {
        case .some(true), .none: return .ready(db)
        case .some(false):
            sqlite3_close(db)
            return .damaged
        }
    }

    /// SQLite's own consistency check, which catches damage the schema step
    /// doesn't touch. `nil` means it couldn't say — never treated as damage.
    private static func quickCheck(_ db: OpaquePointer) -> Bool? {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, nil)
        guard prepared == SQLITE_OK else { return isDamage(prepared) ? false : nil }
        defer { sqlite3_finalize(statement) }
        let step = sqlite3_step(statement)
        guard step == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else {
            return isDamage(step) ? false : nil
        }
        return String(cString: text) == "ok"
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    // MARK: - Settings

    func set(_ value: String, forKey key: String) throws {
        try execute("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", binds: [.text(key), .text(value)])
    }

    func allSettings() -> [String: String] {
        query("SELECT key, value FROM settings") { row in
            (Self.text(row, 0), Self.text(row, 1))
        }.reduce(into: [:]) { $0[$1.0] = $1.1 }
    }

    // MARK: - Torrent records

    func upsertTorrent(_ snapshot: TorrentSnapshot, policy: SeedPolicy, pinned: Bool) throws {
        try execute(
            "INSERT INTO torrents(id, name, pinned, policy, added_at, save_directory) VALUES(?,?,?,?,?,?) " +
            "ON CONFLICT(id) DO UPDATE SET name=excluded.name, pinned=excluded.pinned, policy=excluded.policy, save_directory=excluded.save_directory",
            binds: [
                .text(snapshot.id.raw),
                .text(snapshot.name),
                .text(pinned ? "1" : "0"),
                .text(policyKey(policy)),
                .double(snapshot.addedAt.timeIntervalSince1970),
                .text(snapshot.saveDirectory.absoluteString),
            ]
        )
    }

    func deleteTorrent(id: TorrentID) throws {
        try execute("DELETE FROM torrents WHERE id = ?", binds: [.text(id.raw)])
        try execute("DELETE FROM resume_data WHERE id = ?", binds: [.text(id.raw)])
    }

    func loadTorrentRecords() -> [(id: TorrentID, name: String, pinned: Bool, policy: SeedPolicy, addedAt: Date, directory: URL)] {
        query(
            "SELECT id, name, pinned, policy, added_at, save_directory FROM torrents ORDER BY added_at DESC"
        ) { row in
            (
                TorrentID(Self.text(row, 0)),
                Self.text(row, 1),
                Self.text(row, 2) == "1",
                Self.policy(fromKey: Self.text(row, 3)),
                Date(timeIntervalSince1970: Self.double(row, 4)),
                URL(string: Self.text(row, 5)) ?? FileManager.default.temporaryDirectory
            )
        }
    }

    // MARK: - Resume data

    func storeResumeData(_ data: Data, for id: TorrentID) throws {
        try execute(
            "INSERT INTO resume_data(id, blob) VALUES(?, ?) ON CONFLICT(id) DO UPDATE SET blob = excluded.blob",
            binds: [.text(id.raw)],
            blob: data
        )
    }

    func allResumeData() -> [(id: TorrentID, data: Data)] {
        query("SELECT id, blob FROM resume_data") { row in
            guard let blob = sqlite3_column_blob(row, 1) else { return nil }
            let count = Int(sqlite3_column_bytes(row, 1))
            return (
                TorrentID(Self.text(row, 0)),
                Data(bytes: blob, count: count)
            )
        }
        .compactMap { $0 }
    }

    // MARK: - Decisions

    func recordDecision(_ decision: DecisionRecord) throws {
        let encoder = JSONEncoder()
        let reasons = (try? encoder.encode(decision.reasons)) ?? Data("[]".utf8)
        try execute(
            "INSERT OR REPLACE INTO decisions(id, kind, torrent_id, torrent_name, date, reasons) VALUES(?,?,?,?,?,?)",
            binds: [
                .text(decision.id.uuidString),
                .text(decision.kind.rawValue),
                decision.torrentID.map { .text($0.raw) },
                decision.torrentName.map { .text($0) },
                .double(decision.date.timeIntervalSince1970),
                .text(String(data: reasons, encoding: .utf8) ?? "[]"),
            ]
        )
    }

    func recentDecisions(limit: Int) -> [DecisionRecord] {
        query("SELECT id, kind, torrent_id, torrent_name, date, reasons FROM decisions ORDER BY date DESC LIMIT \(max(1, limit))") { row in
            let rawReasons = Self.text(row, 5).data(using: .utf8)
            let reasons = rawReasons.flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            return DecisionRecord(
                id: UUID(uuidString: Self.text(row, 0)) ?? UUID(),
                kind: DecisionRecord.Kind(rawValue: Self.text(row, 1)) ?? .seedingKept,
                torrentID: Self.optionalText(row, 2).map { TorrentID($0) },
                torrentName: Self.optionalText(row, 3),
                date: Date(timeIntervalSince1970: Self.double(row, 4)),
                reasons: reasons
            )
        }
    }

    // MARK: - SQLite plumbing

    private func policyKey(_ policy: SeedPolicy) -> String {
        switch policy {
        case .balanced: return "balanced"
        case .helpful: return "helpful"
        case .archive: return "archive"
        case .temporary: return "temporary"
        }
    }

    nonisolated private static func policy(fromKey raw: String) -> SeedPolicy {
        switch raw {
        case "helpful": return .helpful
        case "archive": return .archive
        case "temporary": return .temporary
        default: return .balanced
        }
    }

    private func execute(_ sql: String, binds: [DatabaseValue?], blob: Data? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (index, value) in binds.enumerated() {
            let i = Int32(index + 1)
            switch value {
            case .text(let t): sqlite3_bind_text(statement, i, t, -1, SQLITE_TRANSIENT)
            case .double(let d): sqlite3_bind_double(statement, i, d)
            case .none: sqlite3_bind_null(statement, i)
            }
        }
        if let blob {
            blob.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(statement, Int32(binds.count + 1), bytes.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
        }

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.step(String(cString: sqlite3_errmsg(handle)))
        }
    }

    private func query<T>(_ sql: String, map: (OpaquePointer) -> T) -> [T] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return [] }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(map(statement!))
        }
        return results
    }

    nonisolated private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: cString)
    }

    nonisolated private static func double(_ statement: OpaquePointer?, _ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    nonisolated private static func optionalText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return text(statement, index)
    }
}

enum DatabaseValue {
    case text(String)
    case double(Double)
}

enum DatabaseError: Error {
    case prepare(String)
    case step(String)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
