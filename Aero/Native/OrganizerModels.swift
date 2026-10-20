import Foundation

// What Organizer's `calendar` answers (projects/organizer/organizer_timeline.py), as the phone page draws it from the
// same answer (aero_web.py, blocks organizer.day / .week / .month / .year). Organizer decides what is shown, in what order and in which
// colour; this file only reads it. Nothing is computed here that Organizer said, and no colour is chosen here: a colour is a name or a
// hex value that Organizer (or Colony, for an event's calendar) keeps.
//
// Decoded with `.convertFromSnakeCase` (see OrganizerAPI). Nothing here was compiled when it was written (no Mac was at hand);
// it is meant to be conventional enough for the GitHub Actions build to accept, and to be fixed from its output if not.

enum CalendarSpan: String, Codable, CaseIterable, Identifiable {
    case day, week, month, year
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// out to in: year, month, week, day
    static let zoomOrder: [CalendarSpan] = [.year, .month, .week, .day]
}

enum DayMode: String, Codable {
    case timeline, simple
}

/// Where a thing opens: its owner's own screen (Organizer's item, or Colony's event).
struct OpenRef: Codable, Hashable {
    var app: String
    var id: String
    var occurrence: String?
}

struct QuestionChoice: Codable, Hashable, Identifiable {
    var index: Int
    var label: String
    var answer: Change
    var id: Int { index }
}

/// A change Organizer sent with a choice: the same `update` the item's own screen would send.
struct Change: Codable, Hashable {
    var name: String
    var args: [String: JSONValue]
}

struct Question: Codable, Hashable, Identifiable {
    var id: String
    var ask: String
    var capture: String
    /// The item's own title, when the answer carries it (the phone's does); the PC's names only what was typed.
    var title: String?
    var choices: [QuestionChoice]
}

/// Where a thing put off went: its new day (and time), said as "Friday 4:00 PM". The old day's quiet row opens that day.
struct MovedTo: Codable, Hashable {
    var date: String
    var time: String?
    var text: String
}

struct DayItem: Codable, Hashable, Identifiable {
    var kind: String?                 // "item", "now" or "free" in a timeline's rows
    var id: String
    var source: String?               // "organizer" or "colony"
    var type: String?
    var title: String?
    var time: String?
    var timeText: String?
    var endText: String?
    var allDay: Bool?
    var state: String?                // open, done, unmarked; "moved" and "was_due" are quiet rows that only say where a thing went or was due
    /// Was it done? Four values from the records (Aryn, 2026-10-19): "yes" a done is recorded, "no" a skip is, "all" both, "none" neither
    /// (not marked done). One answer for every row of a task, so every surface reads the same thing.
    var doneState: String?
    var markText: String?             // "Moved from Thursday", "Moved to Friday 4:00 PM", "Done later, on Saturday", "Was due Thursday"
    var movedTo: MovedTo?
    var doneAtText: String?
    var since: String?
    var color: String?
    var icon: String?
    var isRepeat: Bool?
    var open: OpenRef?
    var question: Question?
    /// No record of completion is none, not "late" (Aryn, 2026-10-17): a task's own entry whose day or time passed with nothing recorded.
    var unmarked: Bool?
    var until: String?
    var untilWords: String?
    var text: String?                 // a "free" row's words

    enum CodingKeys: String, CodingKey {
        case kind, id, source, type, title, time, timeText, endText, allDay, state, doneAtText, since, color, icon, markText, movedTo, doneState
        case isRepeat = "repeat"
        case open, question, unmarked, until, untilWords, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        // a "now" or "free" row has no id
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        source = try c.decodeIfPresent(String.self, forKey: .source)
        type = try c.decodeIfPresent(String.self, forKey: .type)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        time = try c.decodeIfPresent(String.self, forKey: .time)
        timeText = try c.decodeIfPresent(String.self, forKey: .timeText)
        endText = try c.decodeIfPresent(String.self, forKey: .endText)
        allDay = try c.decodeIfPresent(Bool.self, forKey: .allDay)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        markText = try c.decodeIfPresent(String.self, forKey: .markText)
        doneState = try c.decodeIfPresent(String.self, forKey: .doneState)
        movedTo = try c.decodeIfPresent(MovedTo.self, forKey: .movedTo)
        doneAtText = try c.decodeIfPresent(String.self, forKey: .doneAtText)
        since = try c.decodeIfPresent(String.self, forKey: .since)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        isRepeat = try c.decodeIfPresent(Bool.self, forKey: .isRepeat)
        open = try c.decodeIfPresent(OpenRef.self, forKey: .open)
        question = try c.decodeIfPresent(Question.self, forKey: .question)
        unmarked = try c.decodeIfPresent(Bool.self, forKey: .unmarked)
        until = try c.decodeIfPresent(String.self, forKey: .until)
        untilWords = try c.decodeIfPresent(String.self, forKey: .untilWords)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }
}

extension DayItem {
    /// One identity per row: a repeat can have several rows under one task id on a day (its own times, a put-off one, a done one).
    var rowKey: String { id + "|" + (timeText ?? "") + "|" + (state ?? "") + "|" + (markText ?? "") }
}

struct SimpleNext: Codable, Hashable {
    var id: String
    var title: String
    var color: String?
    var icon: String?
    var source: String?
    var open: OpenRef
    var timeText: String?
    var line: String
    var button: String
    /// Others at the same time: none of them is first (`next` is only the first as the book gave them).
    var also: [SimpleAlso]?
}

struct SimpleAlso: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var source: String?
}

struct SimpleLine: Codable, Hashable, Identifiable {
    var id: String
    var title: String?
    var timeText: String?
    var text: String?
}

struct SimpleDay: Codable, Hashable {
    var greeting: String
    var clock: String
    var next: SimpleNext?
    /// Everything that is next, together, when several are at the same time (the viewer's own order or reading direction orders them).
    var nexts: [SimpleNext]?
    var unmarked: [SimpleLine]
    var later: [SimpleLine]
    var did: [SimpleLine]
    var none: String
}

struct DayAnswer: Codable {
    var date: String
    var label: String
    var dateText: String
    var isToday: Bool
    var prev: String
    var next: String
    var rows: [DayItem]
    var anytime: [DayItem]
    var simple: SimpleDay
}

struct Pill: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var timeText: String
    var color: String
    var icon: String
    var state: String
    var source: String
    var question: Bool
    var markText: String?
}

struct WeekDay: Codable, Hashable, Identifiable {
    var date: String
    var day: Int
    var weekday: String
    var today: Bool
    var free: Bool
    var pills: [Pill]
    var id: String { date }
}

struct WeekAnswer: Codable {
    var text: String
    var days: [WeekDay]
    var prev: String
    var next: String
}

struct MonthCell: Codable, Hashable, Identifiable {
    var date: String
    var day: Int
    var inMonth: Bool
    var today: Bool
    var count: Int
    var colors: [String]
    var question: Bool
    var pills: [Pill]
    var id: String { date }
}

struct MonthAnswer: Codable {
    var text: String
    var weekdays: [String]
    var cells: [MonthCell]
    var prev: String
    var next: String
}

struct YearDay: Codable, Hashable, Identifiable {
    var date: String
    var count: Int
    var level: Int
    var today: Bool
    var question: Bool
    var id: String { date }
}

struct YearMonth: Codable, Hashable, Identifiable {
    var month: String
    var name: String
    var offset: Int
    var days: [YearDay]
    var now: Bool
    var id: String { month }
}

struct YearAnswer: Codable {
    var text: String
    var months: [YearMonth]
    var why: String
    var prev: String
    var next: String
}

struct CalendarAnswer: Codable {
    var span: CalendarSpan
    var mode: DayMode
    var today: String
    var date: String
    var note: String
    var day: DayAnswer?
    var week: WeekAnswer?
    var month: MonthAnswer?
    var year: YearAnswer?
}

/// A JSON value of any shape, for the change a question's choice carries (sent back as it came).
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}
