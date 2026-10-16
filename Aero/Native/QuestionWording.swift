import Foundation

/// A question as the screens say it: the thing's own title once, one short question, and answers that say only what differs. The reader's own
/// words for a reading ("9:00 PM Today · Wednesday 14 October") and its own question ("at 9: 9:00 PM Wednesday 14 Oct or 9:00 AM Thursday 15
/// Oct?") are for the PC's long form; the phone and the day say it shortly (projects/aero/wording_conventions.md: plain, sentence case).
///
/// What this reads is the shape of the labels, not the reader's internals: it drops what every answer has in common, and says what is left.
/// The shapes it knows (a clock time with AM or PM; a weekday and date; a date) are the reader's; any other label is shown as it came.
struct QuestionWords: Equatable {
    var title: String
    /// The words as typed, only when they are not the title.
    var typed: String?
    var ask: String
    var chips: [Chip]

    struct Chip: Equatable, Identifiable {
        var id: Int
        var text: String
    }

    static let relative = ["Today", "Tomorrow", "Yesterday"]
    private static let weekdays = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    private static func short(_ word: String) -> String {
        if weekdays.contains(word) || months.contains(word) { return String(word.prefix(3)) }
        return word
    }

    private static func tokens(_ label: String) -> [String] {
        label.replacingOccurrences(of: "·", with: " ").split(separator: " ").map(String.init)
    }

    /// "9:00" -> "9", "9:30" stays.
    private static func clock(_ token: String) -> String { token.hasSuffix(":00") ? String(token.dropLast(3)) : token }

    static func make(question: Question) -> QuestionWords {
        let title = question.title ?? question.capture, typed = question.capture
        let shownTitle = title.prefix(1).uppercased() + title.dropFirst()
        let words = question.choices.map { tokens($0.label) }
        let labels = question.choices.map(\.label)
        let typedLine: String? = typed.trimmingCharacters(in: .whitespaces).isEmpty || typed.lowercased() == title.lowercased() ? nil : typed

        // a clock time that is AM in one answer and PM in another: "9 in the morning or evening?", answers "9 PM today" and "9 AM tomorrow"
        if words.allSatisfy({ $0.contains(where: { ["AM", "PM"].contains($0) }) }),
           Set(words.map { $0.first ?? "" }).count == 1, let hour = words.first?.first {
            let chips = zip(question.choices, words).map { c, w -> Chip in
                let ampm = w.first(where: { ["AM", "PM"].contains($0) }) ?? ""
                // the day is said only when the answers are on different days
                let days = Set(words.map { $0.first(where: { relative.contains($0) }) ?? "" })
                let day = days.count > 1 ? (w.first(where: { relative.contains($0) }).map { " " + $0.lowercased() } ?? "") : ""
                return Chip(id: c.index, text: "\(clock(hour)) \(ampm)\(day)")
            }
            return QuestionWords(title: shownTitle, typed: typedLine, ask: "\(clock(hour)) in the morning or evening?", chips: chips)
        }

        // the same weekday on different dates ("next Friday"): "Which Friday?", answers "Fri 16" and "Fri 23"
        if let first = words.first, let day = first.first(where: { weekdays.contains($0) }),
           words.allSatisfy({ $0.contains(day) }), words.allSatisfy({ $0.contains(where: { Int($0) != nil }) }),
           Set(labels).count == labels.count {
            let chips = zip(question.choices, words).map { c, w in
                Chip(id: c.index, text: "\(short(day)) \(w.first(where: { Int($0) != nil && ($0.count <= 2) }) ?? "")")
            }
            return QuestionWords(title: shownTitle, typed: typedLine, ask: "Which \(day)?", chips: chips)
        }

        // dates: drop what every answer shares, abbreviate the weekday and month
        let shared = Set(words.first ?? []).filter { t in words.allSatisfy { $0.contains(t) } }
        let chips = zip(question.choices, words).map { c, w -> Chip in
            let rest = w.filter { !shared.contains($0) }
            let kept = rest.isEmpty ? w : rest
            return Chip(id: c.index, text: kept.map(short).joined(separator: " "))
        }
        let anyDate = words.contains { $0.contains(where: { weekdays.contains($0) || months.contains($0) }) }
        return QuestionWords(title: shownTitle, typed: typedLine, ask: anyDate ? "Which date?" : "Which one?", chips: chips)
    }
}
