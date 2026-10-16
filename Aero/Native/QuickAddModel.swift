import Foundation
import SwiftUI

/// The words for when a thing is for, said the way a person says it: today, tomorrow, a weekday within the week, otherwise the date.
enum SavedWords {
    private static func formatter(_ calendar: Calendar, _ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.dateFormat = format
        return f
    }

    /// "today", "tomorrow", "Friday", "23 Oct" (with the year when it is not this one) from a kept time; nil when it is not a date.
    static func dayWord(_ kept: String, now: Date, calendar: Calendar = .current) -> String? {
        guard kept.count >= 10, let day = formatter(calendar, "yyyy-MM-dd").date(from: String(kept.prefix(10))) else { return nil }
        let delta = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 0
        switch delta {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...6: return formatter(calendar, "EEEE").string(from: day)
        default:
            let sameYear = calendar.component(.year, from: day) == calendar.component(.year, from: now)
            return formatter(calendar, sameYear ? "d MMM" : "d MMM yyyy").string(from: day)
        }
    }

    /// "7:30 am" from "YYYY-MM-DD HH:MM"; nil when the kept time has no hour (a date alone).
    static func clockWord(_ kept: String) -> String? {
        guard kept.count >= 16 else { return nil }
        let chars = Array(kept)
        guard let h = Int(String(chars[11..<13])), let m = Int(String(chars[14..<16])) else { return nil }
        let h12 = h % 12 == 0 ? 12 : h % 12
        return "\(h12):" + String(format: "%02d", m) + (h < 12 ? " am" : " pm")
    }

    /// "tomorrow at 7:30 am", "tomorrow", or the kept text itself when it is not a date.
    static func whenText(_ kept: String, now: Date, calendar: Calendar = .current) -> String {
        guard let day = dayWord(kept, now: now, calendar: calendar) else { return kept }
        return clockWord(kept).map { day + " at " + $0 } ?? day
    }

    /// What was saved, as a result: "Saved for tomorrow: call mom".
    static func saved(title: String, when kept: String?, now: Date, calendar: Calendar = .current) -> String {
        guard let kept else { return "Saved without a day: " + title }
        return "Saved for " + whenText(kept, now: now, calendar: calendar) + ": " + title
    }
}

/// The result of a typed line, shown quietly at the box: what was saved and when (with Undo), or, when something stopped, the one shape:
/// what was being done, which step stopped, and a key that does what can be done now. Never silent.
@MainActor
final class QuickAddModel: ObservableObject {
    struct Saved: Equatable {
        var words: String
        /// Short ids to take back; empty when there is nothing the app can undo.
        var refs: [String]
        var title: String
        /// The day it is for ("YYYY-MM-DD"), when it has one, so the note can offer to open that day.
        var day: String?
    }

    struct Stopped: Equatable {
        enum Action: Equatable { case add(String), undo([String], String) }
        var doing: String
        var step: String
        var next: String
        var key: String
        var action: Action
        var text: String { "\(doing) stopped at \(step). \(next)" }
    }

    @Published private(set) var saved: Saved?
    @Published private(set) var stopped: Stopped?
    /// The question a line the reader was not sure of raised; the box shows it in a sheet.
    @Published var asking: QuickAddOutcome?

    let backend: OrganizerBackend
    var onChanged: () -> Void = {}
    private let clock: () -> Date

    init(backend: OrganizerBackend = OrganizerBackends.current(), clock: @escaping () -> Date = Date.init) {
        self.backend = backend
        self.clock = clock
    }

    /// The quiet note goes away when the person starts a new line.
    func clear() { saved = nil; stopped = nil }

    func submit(_ typed: String) async {
        let line = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        clear()
        do {
            let outcome = try await backend.quickAdd(line)
            if outcome.question != nil { asking = outcome }
            if outcome.alreadyThere {
                saved = Saved(words: "Already on your list: " + outcome.title, refs: [], title: outcome.title, day: nil)
            } else if backend.kind == .pc {
                saved = Saved(words: "Sent to your PC: " + outcome.title, refs: [], title: outcome.title, day: nil)
            } else {
                saved = Saved(words: SavedWords.saved(title: outcome.title, when: outcome.when, now: clock()), refs: outcome.saved, title: outcome.title,
                              day: outcome.when.flatMap { $0.count >= 10 ? String($0.prefix(10)) : nil })
            }
        } catch {
            let step = (error as? QuickAddStopped)?.step.rawValue ?? (backend.kind == .pc ? QuickAddStopped.Step.asking.rawValue : QuickAddStopped.Step.keeping.rawValue)
            stopped = Stopped(doing: "Saving \u{201C}\(line)\u{201D}", step: step, next: "Your words are kept here.", key: "Try again", action: .add(line))
        }
        onChanged()
    }

    /// Take back what the last line made. The records stay as versions marked dropped; nothing is erased.
    func undo() async {
        guard let s = saved, !s.refs.isEmpty else { return }
        await take(back: s.refs, title: s.title)
    }

    private func take(back refs: [String], title: String) async {
        do {
            for ref in refs { try await backend.send("drop", ["id": .string(ref)]) }
            stopped = nil
            asking = nil
            saved = Saved(words: "Taken back: " + title, refs: [], title: title, day: nil)
        } catch {
            saved = nil
            stopped = Stopped(doing: "Taking back \u{201C}\(title)\u{201D}", step: "keeping it on your phone", next: "It is still saved.", key: "Try again", action: .undo(refs, title))
        }
        onChanged()
    }

    func retry() async {
        guard let action = stopped?.action else { return }
        switch action {
        case .add(let line): await submit(line)
        case .undo(let refs, let title): await take(back: refs, title: title)
        }
    }
}

/// The tabs around the one held date, as the web Organizer has them: Day, Week, Month, Year and Lists.
enum DayTab: String, CaseIterable, Identifiable {
    case day, week, month, year, lists
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var span: CalendarSpan? { CalendarSpan(rawValue: rawValue) }
    init(span: CalendarSpan) { self = DayTab(rawValue: span.rawValue) ?? .day }
}
