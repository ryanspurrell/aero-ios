import Foundation

/// Whole minutes since 1970, the unit of every time in the Lean file.
enum FieldClock {
    static func now() -> Int { Int(Date().timeIntervalSince1970 / 60) }

    static func date(_ minutes: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minutes) * 60) }

    static func minutes(_ date: Date) -> Int { Int(date.timeIntervalSince1970 / 60) }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
    private static let dateTimeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f
    }()

    /// "2:45 PM"
    static func time(_ minutes: Int) -> String { timeFormat.string(from: date(minutes)) }

    /// "Oct 23, 2026 at 2:45 PM"
    static func dateTime(_ minutes: Int) -> String { dateTimeFormat.string(from: date(minutes)) }

    /// "1 h 12 min", "42 min", "0 min": a whole number of minutes in few words.
    static func span(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return m >= 60 ? (m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min") : "\(m) min"
    }
}
