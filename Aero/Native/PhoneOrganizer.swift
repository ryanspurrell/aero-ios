import Foundation

/// Organizer on the phone, with no PC: the records are the phone's own (PhoneStore), the words are read by the same Python reader the PC
/// uses (embedded in the app), and the day is arranged by the same Python that arranges the PC's day (organizer_timeline.py). What this
/// file does itself is what the PC's service does around those: keep a new version for each change, name the version it replaces, and
/// stamp it with this installation.
final class PhoneOrganizer: OrganizerBackend {
    enum Failure: LocalizedError {
        case notOnPhone(String), noSuchItem
        var errorDescription: String? {
            switch self {
            case .notOnPhone: return "Not on this phone yet."
            case .noSuchItem: return "Item not found."
            }
        }
    }

    var kind: BackendKind { .phone }
    let store: PhoneStore
    let reader: ReaderRunning
    let reminders: PhoneReminders?
    private let clock: () -> Date
    /// Who made a change, as the PC's `by` (the person; the installation is `install`).
    static let person = "person:owner"

    init(store: PhoneStore, reader: ReaderRunning, reminders: PhoneReminders? = nil, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.reader = reader
        self.reminders = reminders
        self.clock = clock
    }

    /// The app's own: records in Application Support, the embedded reader, reminders through the system.
    static func standard() -> PhoneOrganizer {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        let name = DemoMode.isOn ? "organizer-demo.sqlite" : "organizer.sqlite"
        let path = folder.appendingPathComponent(name).path
        if DemoMode.isOn { try? FileManager.default.removeItem(atPath: path) }
        let store = (try? PhoneStore(path: path)) ?? (try! PhoneStore(path: nil))
        return PhoneOrganizer(store: store, reader: EmbeddedReader.shared, reminders: PhoneReminders(center: DemoMode.isOn ? DemoNotifications() : SystemNotifications()))
    }

    // MARK: the clock, as the Python side wants it

    private func nowText() -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: clock())
    }

    /// 'YYYY-MM-DD HH:MM' in the phone's time, as records keep `changed`, `done_at`.
    private func shown(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func recordsJSON(_ book: OrganizerBook) -> JSONValue {
        .array(book.now.map { oid, v in .object(["oid": .string(oid), "id": .string(v.id), "rec": .object(v.rec)]) })
    }

    // MARK: the day

    func calendar(span: CalendarSpan, date: String) async throws -> CalendarAnswer {
        let book = try store.book()
        return try await reader.decode("calendar", ["records": recordsJSON(book), "span": .string(span.rawValue), "date": .string(date), "now": .string(nowText())],
                                       as: CalendarAnswer.self)
    }

    func helperNames() async -> [String] { [] }

    // MARK: changes

    func apply(_ change: Change) async throws { try await send(change.name, change.args) }

    func send(_ name: String, _ args: [String: JSONValue]) async throws {
        switch name {
        case "complete", "reopen", "drop", "update": try await change(name, args)
        case "quickadd": _ = try await quickAdd(args["text"]?.stringValue ?? "")
        case "help_ask", "day_mode", "look_set": return          // a helper and the view's mode belong to a PC
        default: throw Failure.notOnPhone(name)
        }
    }

    private func firstStatus(_ type: String) -> String {
        ["task": "open", "buy": "open", "project": "active", "decision": "made", "resume": "current", "routine": "on", "timer": "running"][type] ?? "open"
    }

    /// The time fields: setting one of them answers a question that was waiting (the PC's TIME_FIELDS).
    private static let timeFields = ["due", "remind", "repeat", "start", "timing"]

    private func change(_ name: String, _ args: [String: JSONValue]) async throws {
        let book = try store.book()
        guard let ref = args["id"]?.stringValue, let oid = book.find(ref), let before = book.now[oid] else { throw Failure.noSuchItem }
        var rec = before.rec
        let type = rec["type"]?.stringValue ?? "task"
        var why = name
        switch name {
        case "complete":
            if type == "buy" {
                rec["status"] = .string("bought"); rec["bought_at"] = .string(shown(clock())); why = "bought"
            } else if type != "task" {
                rec["status"] = .string("done"); why = "done"
            } else if rec["repeat"]?.stringValue?.isEmpty == false {
                let occ = try await reader.call("occurrence", ["rec": .object(rec)])
                guard let at = occ.objectValue?["at"]?.stringValue else { throw Failure.noSuchItem }
                rec["done_until"] = .string(at)
                if case .number(let n)? = rec["done_count"] { rec["done_count"] = .number(n + 1) } else { rec["done_count"] = .number(1) }
                why = "done for \(at)"
            } else {
                rec["status"] = .string("done"); rec["done_at"] = .string(shown(clock())); why = "done"
            }
        case "reopen":
            rec["status"] = .string(firstStatus(type))
            for k in ["done_at", "bought_at", "aside"] { rec[k] = nil }
            why = "reopened"
        case "drop":
            rec["status"] = .string("dropped"); rec["aside"] = nil; why = "dropped"
        default:    // update
            let fields = args.filter { $0.key != "id" && $0.key != "rev" }
            let cleaned = try await reader.call("clean", ["fields": .object(fields)])
            for (k, v) in cleaned.objectValue ?? [:] { rec[k] = v }
            why = "changed"
            try await answered(before: before.rec, rec: &rec)
        }
        rec["changed"] = .string(shown(clock()))
        rec["basis"] = .object(["status": .string("said"), "by": .string(Self.person)])
        try store.put(oid: oid, rec: rec, by: Self.person, why: why, replaces: before.id)
        refreshRemindersInBackground()
    }

    /// A line quick add was not sure of is answered when the person sets its time: choosing one of the kept readings is an `update`
    /// with that reading's own fields (organizer_service.py `answered`). `picked` says which kept reading the new fields match.
    private func answered(before: [String: JSONValue], rec: inout [String: JSONValue]) async throws {
        guard var rd = before["readings"]?.objectValue, rd["state"]?.stringValue == "not answered",
              Self.timeFields.contains(where: { (before[$0]?.stringValue ?? "") != (rec[$0]?.stringValue ?? "") }) else { return }
        var picked: JSONValue = .null
        for (i, k) in (rd["kept"]?.arrayValue ?? []).enumerated() {
            guard let items = k.objectValue?["items"]?.arrayValue, items.count == 1, let args = items[0].objectValue?["args"]?.objectValue else { continue }
            let norm = try await reader.call("clean", ["fields": .object(args)]).objectValue ?? [:]
            if Self.timeFields.allSatisfy({ f in args[f] == nil || (norm[f]?.stringValue ?? "") == (rec[f]?.stringValue ?? "") }) {
                picked = .number(Double(i)); break
            }
        }
        rd["state"] = .string("answered"); rd["answered_at"] = .string(shown(clock())); rd["picked"] = picked
        rec["readings"] = .object(rd)
    }

    // MARK: quick add

    func quickAdd(_ text: String) async throws -> QuickAddOutcome {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let book = try store.book()
        let lists: [JSONValue] = book.now.filter { $0.value.type == "project" && ["active", "parked"].contains($0.value.status) }
            .map { .object(["id": .string($0.key), "title": .string($0.value.title)]) }
        let got = try await reader.call("quickadd", ["text": .string(line), "now": .string(nowText()), "lists": .array(lists)])
        guard let object = got.objectValue, let first = object["first"]?.objectValue else { throw ReaderFailure.said("no item came back") }
        var made: [(String, [String: JSONValue])] = []
        for var rec in [first] + (object["more"]?.arrayValue?.compactMap { $0.objectValue } ?? []) {
            // a thing to buy already on the list is said, not added twice (the PC's rule)
            if rec["type"]?.stringValue == "buy", let t = rec["title"]?.stringValue?.lowercased(),
               book.now.values.contains(where: { $0.type == "buy" && $0.status == "open" && $0.title.lowercased() == t }) { continue }
            rec["changed"] = .string(shown(clock()))
            rec["basis"] = .object(["status": .string("said"), "by": .string(Self.person)])
            rec["locked"] = .bool(false)             // Open: the phone has no Locked mode yet, and the day shows only what is marked Open
            let oid = PhoneStore.newID()
            try store.put(oid: oid, rec: rec, by: Self.person, why: "added", replaces: nil)
            made.append((oid, rec))
        }
        refreshRemindersInBackground()
        guard let (oid, rec) = made.first else { return QuickAddOutcome(title: first["title"]?.stringValue ?? line, typed: line, question: nil, likeliest: nil) }
        return QuickAddOutcome(title: rec["title"]?.stringValue ?? line, typed: line, question: Self.question(oid: oid, rec: rec), likeliest: Self.likeliest(rec))
    }

    /// The question a record still holds (organizer_timeline.py `question_of`): only a reading that is one plain item can be chosen, and
    /// only while the readings are not answered or assumed. Each choice carries the `update` that answers it.
    static func question(oid: String, rec: [String: JSONValue]) -> Question? {
        guard let rd = rec["readings"]?.objectValue, rd["state"]?.stringValue == "not answered", rd["assumed"]?.boolValue != true else { return nil }
        var choices: [QuestionChoice] = []
        for (i, k) in (rd["kept"]?.arrayValue ?? []).enumerated() {
            guard let o = k.objectValue, let items = o["items"]?.arrayValue, items.count == 1, let args = items[0].objectValue?["args"]?.objectValue else { continue }
            var answer = args
            answer["id"] = .string(String(oid.prefix(8)))
            choices.append(QuestionChoice(index: i, label: o["label"]?.stringValue ?? "", answer: Change(name: "update", args: answer)))
        }
        guard !choices.isEmpty else { return nil }
        return Question(id: String(oid.prefix(8)), ask: rd["ask"]?.stringValue ?? "", capture: rec["capture"]?.stringValue ?? rec["title"]?.stringValue ?? "", title: rec["title"]?.stringValue, choices: choices)
    }

    /// "Likeliest" is said only where one reading really is likelier than the next; the numbers are guesses until her answers teach them.
    static func likeliest(_ rec: [String: JSONValue]) -> Int? {
        let kept = rec["readings"]?.objectValue?["kept"]?.arrayValue ?? []
        func p(_ v: JSONValue) -> Double { if case .number(let n)? = v.objectValue?["likelihood"] { return n } else { return 0 } }
        guard kept.count > 1, p(kept[0]) > p(kept[1]) else { return nil }
        return 0
    }

    /// "Something else": none of the readings offered fits. The line stays a plain task, marked for today (attention now) so it is not lost
    /// from the day; its readings are marked declined (not answered is not declined).
    func keepPlain(_ question: Question) async throws {
        let book = try store.book()
        guard let oid = book.find(question.id), let before = book.now[oid] else { throw Failure.noSuchItem }
        var rec = before.rec
        if var rd = rec["readings"]?.objectValue { rd["state"] = .string("declined"); rd["answered_at"] = .string(shown(clock())); rec["readings"] = .object(rd) }
        rec["attention"] = .string("now")
        rec["changed"] = .string(shown(clock()))
        try store.put(oid: oid, rec: rec, by: Self.person, why: "kept as typed", replaces: before.id)
        refreshRemindersInBackground()
    }

    // MARK: reminders

    /// Reminders are set after a change without making the change wait: the first time, the system asks for permission, and a person's
    /// answer to that must not hold up adding a task.
    func refreshRemindersInBackground() {
        Task { await refreshReminders() }
    }

    /// Schedule the nearest times something should be told (PhoneReminders keeps them within iOS's pending limit).
    func refreshReminders() async {
        guard let reminders else { return }
        guard let book = try? store.book() else { return }
        let got = try? await reader.call("upcoming", ["records": recordsJSON(book), "now": .string(nowText()), "limit": .number(Double(PhoneReminders.maxPending))])
        let upcoming: [PhoneReminders.Upcoming] = (got?.arrayValue ?? []).compactMap { v in
            guard let o = v.objectValue, let oid = o["oid"]?.stringValue, let fire = o["fire"]?.stringValue else { return nil }
            return PhoneReminders.Upcoming(oid: oid, title: o["title"]?.stringValue ?? "", fire: fire)
        }
        await reminders.replace(with: upcoming)
    }
}
