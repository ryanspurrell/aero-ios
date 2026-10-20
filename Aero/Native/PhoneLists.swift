import Foundation

/// The Lists tab: what the phone holds that is open, grouped by the list it belongs to. A day shows a thing only on the day it is for, so a
/// thing with no day (a line like "buy milk") is reachable here and nowhere else; this is the one place that has all of them. Nothing is
/// made up: the groups are the phone's own records, read the way the day reads them (open, not set aside, marked Open).
struct ListItem: Identifiable, Hashable {
    /// The record's short id (first 8 characters), as the rest of the app names a record.
    var id: String
    var title: String
    /// When it is for, said in words ("tomorrow at 7:30 am"); nil when it has no day.
    var when: String?
    /// "YYYY-MM-DD" or "YYYY-MM-DD HH:MM" as the record keeps it; nil when it has no day.
    var whenKept: String?
}

struct ListGroup: Identifiable, Hashable {
    /// The list's record id, or "none" for the things in no list.
    var id: String
    var title: String
    var color: String?
    var icon: String?
    var items: [ListItem]
}

enum PhoneLists {
    static func groups(book: OrganizerBook, now: Date = Date(), calendar: Calendar = .current) -> [ListGroup] {
        func isOpenThing(_ v: RecordVersion) -> Bool {
            ["task", "buy"].contains(v.type) && v.status == "open" && v.rec["aside"] == nil && PhoneOrganizer.mayShow(v, in: book)      // an Open task in a Locked list is not shown either
        }
        func item(_ oid: String, _ v: RecordVersion) -> ListItem {
            let kept = PhoneOrganizer.whenOf(v.rec)
            return ListItem(id: String(oid.prefix(8)), title: v.title, when: kept.map { SavedWords.whenText($0, now: now, calendar: calendar) }, whenKept: kept)
        }
        // dated first, in date order; then the ones with no day, by title
        func ordered(_ items: [ListItem]) -> [ListItem] {
            items.sorted { a, b in
                switch (a.whenKept, b.whenKept) {
                case let (x?, y?): return x == y ? a.title.lowercased() < b.title.lowercased() : x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.title.lowercased() < b.title.lowercased()
                }
            }
        }
        let open = book.now.filter { isOpenThing($0.value) }
        var out: [ListGroup] = []
        let lists = book.now.filter { $0.value.type == "project" && ["active", "parked"].contains($0.value.status) && PhoneOrganizer.mayShow($0.value, in: book) }
            .sorted { $0.value.title.lowercased() < $1.value.title.lowercased() }
        var placed = Set<String>()
        for (oid, list) in lists {
            let mine = open.filter { $0.value.rec["project"]?.stringValue == oid }
            placed.formUnion(mine.keys)
            guard !mine.isEmpty else { continue }
            out.append(ListGroup(id: oid, title: list.title, color: list.rec["color"]?.stringValue, icon: list.rec["icon"]?.stringValue,
                                 items: ordered(mine.map { item($0.key, $0.value) })))
        }
        let rest = open.filter { !placed.contains($0.key) }
        if !rest.isEmpty {
            out.append(ListGroup(id: "none", title: "Not in a list", color: nil, icon: nil, items: ordered(rest.map { item($0.key, $0.value) })))
        }
        return out
    }
}
