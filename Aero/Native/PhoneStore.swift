import Foundation
import SQLite3

/// The phone's own copy of Organizer's records: every version of every record, in one SQLite file the app owns (the system's SQLite
/// library, no package). The same shape the PC keeps in records.jsonl (OrganizerRecords.swift), the same ids (random 128-bit hex, as the
/// PC's `new_id()`), and the same rule: a change is a new version that names the one it replaces; nothing is overwritten.
///
/// Why SQLite and not SwiftData: SwiftData needs iOS 17 and the app's target is iOS 16.4; Core Data would need a model file and a
/// mapping from each record's open-ended fields. A version's `rec` is kept as the JSON text it is, so a field a newer install adds
/// survives a trip through this one.
final class PhoneStore {
    enum Failure: Error { case open(String), sql(String), changedMeanwhile }

    private var db: OpaquePointer?
    private let lock = NSLock()
    /// This installation's id: random 128-bit hex, made once and kept in the file.
    private(set) var installID: String = ""
    private let clock: () -> Date

    /// `path` nil keeps the records in memory only (tests).
    init(path: String? = nil, clock: @escaping () -> Date = Date.init) throws {
        self.clock = clock
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path ?? ":memory:", &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw Failure.open(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle")
        }
        db = handle
        try run("""
            CREATE TABLE IF NOT EXISTS versions (
              seq INTEGER PRIMARY KEY AUTOINCREMENT,
              id TEXT NOT NULL UNIQUE, at TEXT NOT NULL, oid TEXT NOT NULL, install TEXT, by TEXT, why TEXT, replaces TEXT, key TEXT,
              rec TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS versions_oid ON versions(oid);
            CREATE TABLE IF NOT EXISTS meta (name TEXT PRIMARY KEY, value TEXT NOT NULL);
            """)
        if let kept = try scalar("SELECT value FROM meta WHERE name = 'install'"), kept.count == 32 {
            installID = kept
        } else {
            let made = Self.newID()
            try run("INSERT OR REPLACE INTO meta(name, value) VALUES ('install', ?)", [made])
            installID = made
        }
    }

    deinit { sqlite3_close(db) }

    /// A random 128-bit id in lower-case hex, as `secrets.token_hex(16)` makes.
    static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The time as the PC writes `at`: UTC, %Y-%m-%dT%H:%M:%S.%fZ (six digits of fraction).
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f.string(from: date) + "000Z"
    }

    // MARK: reading and writing

    /// Every version, oldest first (as they were written).
    func versions() throws -> [RecordVersion] {
        lock.lock(); defer { lock.unlock() }
        return try rows("SELECT id, at, oid, install, by, why, replaces, key, rec FROM versions ORDER BY seq").compactMap { r in
            guard let data = r[8]?.data(using: .utf8), let rec = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { return nil }
            return RecordVersion(id: r[0] ?? "", at: r[1] ?? "", kind: "org", oid: r[2] ?? "", rec: rec, by: r[4], why: r[5], replaces: r[6], key: r[7], install: r[3])
        }
    }

    func book() throws -> OrganizerBook { OrganizerBook(try versions()) }

    /// A new version of `oid` (a new record when `replaces` is nil), made here and now by this installation. A tap in it that has no moment
    /// (`"moment": null`) takes the next one in its person's own sequence in this same locked step as the write, from the highest the kept
    /// records hold (organizer_service.py `assign_moments`): a number and the record that holds it are one fact, so a write that fails
    /// leaves no gap and no repeat.
    @discardableResult
    func put(oid: String, rec: [String: JSONValue], by: String, why: String, replaces: String?) throws -> RecordVersion {
        lock.lock(); defer { lock.unlock() }
        // A version replaces the one that is current. If another version already replaces `replaces`, this write was made from a record that
        // has moved on; writing it would leave two heads (a fork) and the day would show only one of them, losing a tap. Refused here, in the
        // one place every writer goes through, so no caller has to remember to check.
        if let replaces, try !rows("SELECT 1 FROM versions WHERE replaces = ? LIMIT 1", [replaces]).isEmpty { throw Failure.changedMeanwhile }
        var rec = rec
        try assignMoments(&rec, by: by)
        let v = RecordVersion(id: Self.newID(), at: Self.stamp(clock()), kind: "org", oid: oid, rec: rec, by: by, why: why, replaces: replaces, key: nil, install: installID)
        try addLocked(v)
        return v
    }

    /// A version made elsewhere (a PC's, later): kept as it came, with its own id and `install`. A version already held is not added twice.
    func add(_ v: RecordVersion) throws {
        lock.lock(); defer { lock.unlock() }
        try addLocked(v)
    }

    private func addLocked(_ v: RecordVersion) throws {
        let json = String(data: try JSONEncoder().encode(v.rec), encoding: .utf8) ?? "{}"
        try run("INSERT OR IGNORE INTO versions(id, at, oid, install, by, why, replaces, key, rec) VALUES (?,?,?,?,?,?,?,?,?)",
                [v.id, v.at, v.oid, v.install, v.by, v.why, v.replaces, v.key, json])
    }

    private static let tapKeys = ["done_ats", "skipped_ats"]

    private static func who(_ w: String) -> String { w.hasPrefix("person:") || w.hasPrefix("device:") ? "anchor" : w }

    private static func moment(_ v: JSONValue?) -> Int? { if case .number(let n)? = v { return Int(n) } else { return nil } }

    /// Fills each tap's missing moment. Caller holds `lock`.
    private func assignMoments(_ rec: inout [String: JSONValue], by: String) throws {
        let needs = Self.tapKeys.contains { k in (rec[k]?.arrayValue ?? []).contains { $0.objectValue?["moment"] == JSONValue.null } }
        guard needs else { return }
        var top: [String: Int] = [:]
        func note(_ r: [String: JSONValue]) {
            for k in Self.tapKeys {
                for x in r[k]?.arrayValue ?? [] {
                    guard let o = x.objectValue, let m = Self.moment(o["moment"]) else { continue }
                    let w = Self.who(o["who"]?.stringValue ?? "")
                    top[w] = max(top[w] ?? 0, m)
                }
            }
        }
        for r in try rows("SELECT rec FROM versions") {
            if let text = r[0], let data = text.data(using: .utf8), let kept = try? JSONDecoder().decode([String: JSONValue].self, from: data) { note(kept) }
        }
        note(rec)
        for k in Self.tapKeys {
            guard var taps = rec[k]?.arrayValue else { continue }
            for i in taps.indices {
                guard var o = taps[i].objectValue, o["moment"] == JSONValue.null else { continue }
                let w = Self.who(o["who"]?.stringValue ?? by)
                let n = (top[w] ?? 0) + 1
                top[w] = n
                o["moment"] = .number(Double(n))
                taps[i] = .object(o)
            }
            rec[k] = .array(taps)
        }
    }

    // MARK: SQLite, minimal

    private func run(_ sql: String, _ args: [String?] = []) throws {
        if args.isEmpty {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let said = err.map { String(cString: $0) } ?? "sql error"
                sqlite3_free(err)
                throw Failure.sql(said)
            }
            return
        }
        _ = try rows(sql, args)
    }

    private func scalar(_ sql: String) throws -> String? { try rows(sql).first?.first ?? nil }

    private func rows(_ sql: String, _ args: [String?] = []) throws -> [[String?]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sql(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)       // SQLITE_TRANSIENT
        for (i, a) in args.enumerated() {
            if let a { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, transient) } else { sqlite3_bind_null(stmt, Int32(i + 1)) }
        }
        var out: [[String?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.sql(String(cString: sqlite3_errmsg(db))) }
            out.append((0..<sqlite3_column_count(stmt)).map { c in
                sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_text(stmt, c).map { String(cString: $0) }
            })
        }
        return out
    }
}
