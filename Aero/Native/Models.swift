import Foundation

// What the server already sends, read leniently: a field the server adds or
// leaves out never stops a screen from drawing. Sources (Aero's server):
// POST private/org {name: "board" | "understand" | "quickadd"}, GET underway.json,
// GET rooms.json?as=<name> (its "view").
//
// A list a struct holds is decoded with `decodeIfPresent` in an extension: the
// synthesized decoder would refuse a missing key even when the property has a
// default, and an extension keeps the memberwise initializer for the fixtures.

/// One thing she was in the middle of (GET underway.json).
struct UnderwayItem: Codable, Identifiable, Hashable {
    var id: String
    var part: String?
    var title: String?
    var why: String?
    var says: String?
    var device: String?
    var left: Double?   // seconds since 1970, when it was left
}

struct UnderwayAnswer: Decodable {
    var items: [UnderwayItem]
}

extension UnderwayAnswer {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([UnderwayItem].self, forKey: .items) ?? []
    }
    private enum CodingKeys: String, CodingKey { case items }
}

/// A tile or a view of Organizer's board, with its count and why it counts.
struct OrganizerTile: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var count: Int?
    var why: String?
}

struct OrganizerList: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var count: Int?
    var group: String?
    var kind: String?    // "list" for a list she made; the shopping list and the like have none
}

/// Organizer's board (name "board").
struct OrganizerBoard: Decodable {
    var tiles: [OrganizerTile]
    var rows: [OrganizerList]
}

extension OrganizerBoard {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tiles = try c.decodeIfPresent([OrganizerTile].self, forKey: .tiles) ?? []
        rows = try c.decodeIfPresent([OrganizerList].self, forKey: .rows) ?? []
    }
    private enum CodingKeys: String, CodingKey { case tiles, rows }
}

/// One choice of a question quick add asks ("which one?").
struct ReadingOption: Codable, Identifiable, Hashable {
    var key: String
    var label: String
    var id: String { key }
}

struct ReadingQuestion: Decodable, Identifiable, Hashable {
    var sched: Int
    var title: String?
    var said: String?
    var options: [ReadingOption]
    var id: Int { sched }
}

extension ReadingQuestion {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sched = try c.decodeIfPresent(Int.self, forKey: .sched) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title)
        said = try c.decodeIfPresent(String.self, forKey: .said)
        options = try c.decodeIfPresent([ReadingOption].self, forKey: .options) ?? []
    }
    private enum CodingKeys: String, CodingKey { case sched, title, said, options }
}

struct Readings: Decodable {
    var questions: [ReadingQuestion]?
}

struct QuickAddArgs: Decodable {
    var title: String?
    var due: String?     // "2026-10-16" or "2026-10-16 21:00"
    var start: String?
    var project: String?
}

/// What quick add understood from the words (names "understand" and "quickadd").
struct QuickAddReading: Decodable {
    var args: QuickAddArgs?
    var readings: Readings?
}

/// One room in the chat list (rooms.json, "view"). Titles and previews are opened on
/// the device, not sent by the server, so a row names the kind of chat.
struct Room: Codable, Identifiable, Hashable {
    var id: String
    var kind: String            // "messages", "manager" or "agent"
    var manager: String?
    var agent: String?
    var pinned: Bool?
    var unread: Int?
    var closed: String?
    var section: String?
}

struct RoomSection: Decodable, Identifiable, Hashable {
    var id: String
    var kind: String?
    var name: String?
    var rooms: [String]
    var unread: Int?
    var folded: Bool?
}

extension RoomSection {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        rooms = try c.decodeIfPresent([String].self, forKey: .rooms) ?? []
        unread = try c.decodeIfPresent(Int.self, forKey: .unread)
        folded = try c.decodeIfPresent(Bool.self, forKey: .folded)
    }
    private enum CodingKeys: String, CodingKey { case id, kind, name, rooms, unread, folded }
}

struct RoomsView: Decodable {
    var unread: Int?
    var rooms: [Room]
    var sections: [RoomSection]
}

extension RoomsView {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unread = try c.decodeIfPresent(Int.self, forKey: .unread)
        rooms = try c.decodeIfPresent([Room].self, forKey: .rooms) ?? []
        sections = try c.decodeIfPresent([RoomSection].self, forKey: .sections) ?? []
    }
    private enum CodingKeys: String, CodingKey { case unread, rooms, sections }
}

struct RoomsAnswer: Decodable {
    var view: RoomsView?
}
