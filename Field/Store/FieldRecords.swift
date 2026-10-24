import Foundation

// The records the app keeps on the device. Shapes only; the rules are in Model/ and cite FieldSample.lean.

/// A ladder or other tool for the trip. `reach` nil is Lean's `none`: said to exist, not measured. The plain list of reaches is what
/// `tripReady` reads (`Tools`).
struct ToolEntry: Hashable, Codable, Identifiable {
    var id: Int
    var name: String
    var reach: Int?
}

/// A person in the chain of custody. The Lean file uses numbers; the name is only for the screen (a stand-in in a practice copy).
struct Person: Hashable, Codable, Identifiable {
    var id: Int
    var name: String
}

/// The four kinds of ticket Aryn listed (2026-10-23, 4:22 pm): an edge case, something to add, a place that does not work, the look.
enum TicketKind: String, Codable, CaseIterable {
    case edgeCase, addition, brokenPlace, look
}

/// A ticket carries the screen, the step and the shape of what happened, never the person's records (ideas__later_2026-10-06.md, "Fingus as work
/// for friends; Fingus Environmental", added 4:22 and 4:24 pm). `to` is the owner of the install the ticket was written in. It stays on the
/// device. The holarchy rule (a ticket reaches the next level only as a ticket written or chosen at this level) has no Lean counterpart yet.
struct Ticket: Hashable, Codable, Identifiable {
    var id: Int
    var kind: TicketKind
    var screen: String
    var step: String
    var what: String
    var to: String
    var practice: Bool
    var made: Int
}

/// "Would this have helped?": yes, no, all (partly), none (can't tell), with an optional note. Kept on the phone.
struct SituationAnswer: Hashable, Codable, Identifiable {
    var id: String { situation }
    var situation: String
    var answer: Four
    var note: String
}

/// Everything the app keeps. One file on the device, excluded from backups, never sent.
struct FieldData: Codable, Equatable {
    var practice = true
    var run: Run = []
    var plan: Run = []
    var tools: [ToolEntry] = []
    var people: [Person] = []
    var handovers: [Handover] = []
    var tickets: [Ticket] = []
    var answers: [SituationAnswer] = []
    var owner = "Owner of this install"
}
