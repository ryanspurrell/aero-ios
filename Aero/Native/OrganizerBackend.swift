import Foundation

/// What the day, week, month, year and home views ask of Organizer. Two things answer it: the PC (OrganizerAPI, through Aero's server)
/// and the phone's own records (PhoneOrganizer). The screens hold an `OrganizerBackend` and never know which.
protocol OrganizerBackend {
    var kind: BackendKind { get }
    func calendar(span: CalendarSpan, date: String) async throws -> CalendarAnswer
    func apply(_ change: Change) async throws
    func send(_ name: String, _ args: [String: JSONValue]) async throws
    func helperNames() async -> [String]
    /// One typed line, read and kept. On the phone the answer carries the question to ask now when the line was not certain.
    func quickAdd(_ text: String) async throws -> QuickAddOutcome
    /// "Something else": none of the readings offered fits; the line stays a plain task.
    func keepPlain(_ question: Question) async throws
    /// The open things grouped by list, for the Lists tab. nil when this backend does not hold them (the PC's lists are drawn by the web view).
    func lists() async throws -> [ListGroup]?
}

enum BackendKind: String { case pc, phone }

extension OrganizerBackend {
    func send(_ name: String) async throws { try await send(name, [:]) }
    func lists() async throws -> [ListGroup]? { nil }
}

/// What a typed line became.
struct QuickAddOutcome {
    var title: String
    /// The words as typed.
    var typed: String
    /// Set when the reader was not sure: the readings still live, to be asked about now. nil when the line was certain.
    var question: Question?
    /// The index of the likeliest choice, only when one reading really is likelier than the next (the web says "Likeliest" only then).
    var likeliest: Int?
    /// The short ids (first 8 characters) of the records the line made, so Undo can take them back. Empty when this backend made none the app
    /// can name (the PC reads the line itself).
    var saved: [String] = []
    /// When the first item was set for, as the record keeps it ("YYYY-MM-DD" or "YYYY-MM-DD HH:MM"); nil when it has no time of its own yet.
    var when: String?
    /// The line was something already on the list, so nothing was added.
    var alreadyThere = false
}

/// Quick add stopped at one named step (the one shape: what was being done, which step stopped, what can be done now).
struct QuickAddStopped: LocalizedError {
    enum Step: String {
        case reading = "reading it"
        case keeping = "keeping it on your phone"
        case asking = "asking your PC"
    }
    var step: Step
    var errorDescription: String? { "Stopped at \(step.rawValue)." }
}

/// Which backend the app uses: the PC when one is set up (an address was entered), otherwise the phone's own records.
enum OrganizerBackends {
    static func current() -> OrganizerBackend {
        AppInfo.address != nil ? OrganizerAPI() : phone
    }

    /// The phone's Organizer, made once. Its file is in the app's Application Support folder.
    static let phone: PhoneOrganizer = PhoneOrganizer.standard()
}

/// A decoder for Organizer's answers: snake_case keys become camelCase, except keys inside `args` (a change's own fields, which are
/// Organizer's names and are sent back as they came, e.g. `part_of_day`).
enum OrganizerDecoder {
    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    static func camel(_ s: String) -> String {
        guard s.contains("_") else { return s }
        let parts = s.split(separator: "_", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return s }
        return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    }

    static func make() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let last = path[path.count - 1]
            if path.dropLast().contains(where: { $0.stringValue == "args" }) { return last }
            return AnyKey(camel(last.stringValue))
        }
        return d
    }
}
