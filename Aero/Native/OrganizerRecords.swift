import Foundation

// The Organizer record shape in Swift (projects/organizer/record_shape.schema.json; the same fields the PC's service writes in
// records.jsonl). One record is a chain of versions; each version names the one it replaces (`replaces`), says when it was made (`at`)
// and on which installation (`install`, a random id kept per install). The phone's own store keeps these and reads them with
// `OrganizerBook`, which follows organizer_service.py's `Book` step for step; AeroTests/RecordShapeTests.swift reads the same fixture
// files the Python tests read and expects the same answers.

/// One version of one record: one line of records.jsonl. Fields this reader does not know are kept inside `rec` (a record from a newer
/// install loses nothing passing through); version-level fields it does not know are not kept.
struct RecordVersion: Codable, Hashable, Identifiable {
    var id: String
    var at: String
    var kind: String
    var oid: String
    var rec: [String: JSONValue]
    var by: String?
    var why: String?
    var replaces: String?
    var key: String?
    /// The installation that made it; nil on a version made before it was kept.
    var install: String?

    var title: String { rec["title"]?.stringValue ?? "" }
    var status: String { rec["status"]?.stringValue ?? "" }
    var type: String { rec["type"]?.stringValue ?? "" }
}

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
}

/// Every version of every record, and the current one of each; the same reading as the PC's `Book`.
struct OrganizerBook {
    /// The current version of each record.
    private(set) var now: [String: RecordVersion] = [:]
    /// Each record's versions, oldest first, following the chain back from its current one.
    private(set) var versions: [String: [RecordVersion]] = [:]
    /// A fork: records with more than one version that nothing replaces (two installs each changed the same version). The later `at`
    /// is still `now`; every head is kept here, oldest first, so the screen can say "both kept, with when and where".
    private(set) var conflicts: [String: [RecordVersion]] = [:]

    init(_ items: [RecordVersion]) {
        // by id; a later line with the same id replaces an earlier one but keeps its place (a Python dict)
        var byID: [String: RecordVersion] = [:]
        var order: [String] = []
        for it in items where !it.oid.isEmpty {
            if byID[it.id] == nil { order.append(it.id) }
            byID[it.id] = it
        }
        let hidden = Set(byID.values.compactMap { $0.replaces }.filter { !$0.isEmpty })
        // sorted by `at`, ties in the order they came (Python's sort is stable)
        let ordered = order.enumerated()
            .sorted { a, b in
                let x = byID[a.element]!.at, y = byID[b.element]!.at
                return x == y ? a.offset < b.offset : x < y
            }
            .map { byID[$0.element]! }
        var heads: [String: [RecordVersion]] = [:]
        for it in ordered where !hidden.contains(it.id) {
            heads[it.oid, default: []].append(it)
            var chain: [RecordVersion] = []
            var cur: RecordVersion? = it
            while let c = cur, chain.count < 1000 {
                chain.append(c)
                cur = c.replaces.flatMap { byID[$0] }
            }
            now[it.oid] = it
            versions[it.oid] = chain.reversed()
        }
        conflicts = heads.filter { $0.value.count > 1 }
    }

    func rec(_ oid: String) -> [String: JSONValue]? { now[oid]?.rec }

    /// The record whose id starts with `ref` (the API names a record by the first 8 characters); nil when none or more than one.
    func find(_ ref: String) -> String? {
        let r = ref.trimmingCharacters(in: .whitespaces).lowercased()
        guard !r.isEmpty else { return nil }
        let hits = now.keys.filter { $0.hasPrefix(r) }
        return hits.count == 1 ? hits[0] : nil
    }
}
