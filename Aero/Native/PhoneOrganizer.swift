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
            case .notOnPhone: return "Not on your phone yet."
            case .noSuchItem: return "That isn't here any more."
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
        do {
            let book = try store.book()
            let got = try await reader.decode("calendar", ["records": recordsJSON(book), "span": .string(span.rawValue), "date": .string(date), "now": .string(nowText())],
                                              as: CalendarAnswer.self)
            await ConnectionMonitor.shared.sawOwn(.reached, backend: .phone)
            return got
        } catch {
            // the phone's own records did not open: the island says so (ConnectionStatus)
            await ConnectionMonitor.shared.sawOwn(.refused, backend: .phone)
            throw error
        }
    }

    func helperNames() async -> [String] { [] }

    // MARK: changes

    func apply(_ change: Change) async throws { try await send(change.name, change.args) }

    func send(_ name: String, _ args: [String: JSONValue]) async throws {
        switch name {
        case "complete", "skip", "reopen", "drop", "update": try await change(name, args)
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

    /// Changes to a record go one at a time: a change reads the record, may wait for the reader (`occurrence`, `clean`), then writes the
    /// next version. Two taps overlapping would both read the same version and both write a successor to it. They now wait their turn,
    /// so the second reads the first's result (the store also refuses a write made from a record that has moved on, `changedMeanwhile`).
    private let turn = Turn()

    private func change(_ name: String, _ args: [String: JSONValue]) async throws {
        await turn.enter()
        defer { turn.leave() }
        try await changeNow(name, args)
    }

    private func changeNow(_ name: String, _ args: [String: JSONValue]) async throws {
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
                // each occurrence is its own instance: a button names the one it is for (`occurrence`); with none it is the current one. The
                // reader checks that a time named is one of the task's own (the PC's `repeat_target`) and refuses it otherwise, writing nothing.
                let named = args["occurrence"]?.stringValue ?? ""
                let got = try await reader.call("target", ["rec": .object(rec), "occurrence": .string(named)]).objectValue ?? [:]
                guard let at = got["current"]?.stringValue, let target = got["at"]?.stringValue else { throw Failure.noSuchItem }
                if case .number(let n)? = rec["done_count"] { rec["done_count"] = .number(n + 1) } else { rec["done_count"] = .number(1) }
                let doneFor = (rec["done_for"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
                rec["done_for"] = .array(Array(NSOrderedSet(array: doneFor + [target])).compactMap { ($0 as? String).map(JSONValue.string) })
                if target == at {
                    // the occurrence that was put off is the one just done: keep that it was moved and when it was done (the PC's `done_moves`), so
                    // its rows can say "Done later" and the day it was done "Was due"; the versions keep the deferral
                    if let held = rec["deferred"]?.objectValue?["until"]?.stringValue {
                        rec["done_moves"] = .array((rec["done_moves"]?.arrayValue ?? []) + [Self.move(from: at, to: held, at: shown(clock()))])
                    }
                    rec["done_until"] = .string(at)
                    rec["deferred"] = nil
                }
                observeDone(&rec, presented: args["presented"], tap: tap(args, oid, before.id, occ: target))     // when, how it was shown, the rest of the tap
                why = "done for \(target)"
            } else {
                rec["status"] = .string("done"); observeDone(&rec, presented: args["presented"], tap: tap(args, oid, before.id)); why = "done"
            }
        case "skip":
            // Skip beside Done (Aryn, 2026-10-19): a dated observation that she skipped it, kept like `done_ats`; it accumulates, nothing is
            // deleted, and only the act is stored (organizer_service.py `skip`).
            guard type == "task" else { throw Failure.noSuchItem }
            let atText = shown(clock())
            var seen = rec["skipped_ats"]?.arrayValue ?? []
            var occText = ""                // which time the tap was for: the one named, else the current one (the PC's `tap_of`); none when it does not repeat
            if rec["repeat"]?.stringValue?.isEmpty == false {
                let named = args["occurrence"]?.stringValue ?? ""
                let got = try await reader.call("target", ["rec": .object(rec), "occurrence": .string(named)]).objectValue ?? [:]      // refused when it is not one of its times
                guard let current = got["current"]?.stringValue, let target = got["at"]?.stringValue else { throw Failure.noSuchItem }
                let skippedFor = (rec["skipped_for"]?.arrayValue ?? []).map { $0.stringValue ?? "" }
                rec["skipped_for"] = .array(Array(NSOrderedSet(array: skippedFor + [target])).compactMap { ($0 as? String).map(JSONValue.string) })
                if target == current {
                    if let held = rec["deferred"]?.objectValue?["until"]?.stringValue {
                        rec["skip_moves"] = .array((rec["skip_moves"]?.arrayValue ?? []) + [Self.move(from: current, to: held, at: atText)])
                    }
                    rec["done_until"] = .string(current)
                    rec["deferred"] = nil
                }
                occText = target
                why = "skipped for \(target)"
            } else {
                why = "skipped"            // every tap is kept (the timeline shows one row a day)
            }
            let entry = Presentation.observation(at: atText, presented: args["presented"], tap: tap(args, oid, before.id, occ: occText))
            seen.append(entry)
            rec["skipped_ats"] = .array(seen)
        case "reopen":
            rec["status"] = .string(firstStatus(type))
            // an older record's one done time is kept as an observation
            if rec["done_ats"] == nil, let at = rec["done_at"] { rec["done_ats"] = .array([at]) }
            for k in ["done_at", "bought_at", "aside"] { rec[k] = nil }
            why = "reopened"
        case "drop":
            rec["status"] = .string("dropped"); rec["aside"] = nil; why = "dropped"
        default:    // update
            let fields = args.filter { $0.key != "id" && $0.key != "rev" }
            let cleaned = try await reader.call("clean", ["fields": .object(fields)])
            let wasDone = rec["status"]?.stringValue == "done"
            for (k, v) in cleaned.objectValue ?? [:] { rec[k] = v }
            // edited to done: the same observation Complete makes, with its time
            if type == "task", rec["repeat"]?.stringValue?.isEmpty != false, rec["status"]?.stringValue == "done", !wasDone { observeDone(&rec, presented: args["presented"], tap: tap(args, oid, before.id)) }
            why = "changed"
            try await answered(before: before.rec, rec: &rec)
        }
        rec["changed"] = .string(shown(clock()))
        rec["basis"] = .object(["status": .string("said"), "by": .string(Self.person)])
        try store.put(oid: oid, rec: rec, by: Self.person, why: why, replaces: before.id)
        refreshRemindersInBackground()
    }

    /// Done is a dated observation that accumulates (organizer_service.py `observe_done`): `done_ats` holds every time it was marked done,
    /// `done_at` the latest. Completing again adds one and never replaces the first.
    /// What a tap records beside its layout (design__tap_record_2026-10-19.md; organizer_service.py `tap_of`): the item's pointer only, never its
    /// title or notes; who; the moment in her own sequence; what she saw (`rev`) and whether it was stale (kept, not refused); device; version.
    private func tap(_ args: [String: JSONValue], _ oid: String, _ currentRev: String, occ: String = "") -> [String: JSONValue] {
        let pres = args["presented"]?.objectValue ?? [:]
        let rev = args["rev"]?.stringValue ?? ""
        var out: [String: JSONValue] = [
            "item": .string("organizer.tasks/" + String(oid.prefix(8))), "asks": .string("done"), "occ": .string(occ), "who": .string(Self.person),
            "moment": .null, "saw": .string(rev),
            "unseen": .bool(!rev.isEmpty && !currentRev.hasPrefix(rev)),
            "device": .string(pres["device"]?.stringValue ?? ""), "writer": .string(Presentation.writer),
            "client": .string(pres["app"]?.stringValue ?? ""), "chosen": .bool(pres["chosen"]?.boolValue ?? false)]
        if case .number(let p)? = pres["prob"], p >= 0, p <= 1 { out["prob"] = .number(p) } else { out["prob"] = .null }
        return out
    }

    private func observeDone(_ rec: inout [String: JSONValue], presented: JSONValue? = nil, tap: [String: JSONValue]? = nil) {
        let atText = shown(clock())
        var seen = rec["done_ats"]?.arrayValue ?? (rec["done_at"].map { [$0] } ?? [])
        seen.append(Presentation.observation(at: atText, presented: presented, tap: tap))     // every tap is kept
        rec["done_ats"] = .array(seen)
        rec["done_at"] = .string(atText)
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
        // each step that can stop is named, so the screen can say which one it was
        let book: OrganizerBook
        do { book = try store.book() } catch { throw QuickAddStopped(step: .keeping) }
        let lists: [JSONValue] = book.now.filter { $0.value.type == "project" && ["active", "parked"].contains($0.value.status) && Self.mayShow($0.value, in: book) }
            .map { .object(["id": .string($0.key), "title": .string($0.value.title)]) }
        let got: JSONValue
        do { got = try await reader.call("quickadd", ["text": .string(line), "now": .string(nowText()), "lists": .array(lists)]) }
        catch { throw QuickAddStopped(step: .reading) }
        guard let object = got.objectValue, let first = object["first"]?.objectValue else { throw QuickAddStopped(step: .reading) }
        var made: [(String, [String: JSONValue])] = []
        for var rec in [first] + (object["more"]?.arrayValue?.compactMap { $0.objectValue } ?? []) {
            // a thing to buy already on the list is said, not added twice (the PC's rule)
            if rec["type"]?.stringValue == "buy", let t = rec["title"]?.stringValue?.lowercased(),
               book.now.values.contains(where: { $0.type == "buy" && $0.status == "open" && $0.title.lowercased() == t && Self.mayShow($0, in: book) }) { continue }
            rec["changed"] = .string(shown(clock()))
            rec["basis"] = .object(["status": .string("said"), "by": .string(Self.person)])
            rec["locked"] = .bool(false)             // Open: the phone has no Locked mode yet, and the day shows only what is marked Open
            let oid = PhoneStore.newID()
            do { try store.put(oid: oid, rec: rec, by: Self.person, why: "added", replaces: nil) } catch { throw QuickAddStopped(step: .keeping) }
            made.append((oid, rec))
        }
        refreshRemindersInBackground()
        guard let (oid, rec) = made.first else {
            return QuickAddOutcome(title: first["title"]?.stringValue ?? line, typed: line, question: nil, likeliest: nil, alreadyThere: true)
        }
        let question = Self.question(oid: oid, rec: rec)
        return QuickAddOutcome(title: rec["title"]?.stringValue ?? line, typed: line, question: question, likeliest: Self.likeliest(rec),
                               saved: made.map { String($0.0.prefix(8)) }, when: question == nil ? Self.whenOf(rec) : nil)
    }

    /// What a Done or Skip of a put-off occurrence keeps (the PC's `done_moves` and `skip_moves`): which time, where it had been moved to, and when
    /// it was acted on. BranchOrganizerDay/Repeats.lean `done_cur`, `skip_cur`: one record, only when the current time is acted on.
    static func move(from: String, to: String, at: String) -> JSONValue {
        .object(["from": .string(from), "to": .string(to), "at": .string(at)])
    }

    /// Whether the phone may show or hand on a record's words: marked Open itself, not private, and not in a list that is Locked or private
    /// (the PC's `is_locked` with `locked == false`; unmarked is private). The phone has no Locked mode, so this is the one gate every
    /// reader of the book goes through: the lists, quick add's list names, and the check for a thing already to buy.
    static func mayShow(_ v: RecordVersion, in book: OrganizerBook) -> Bool {
        guard v.rec["locked"]?.boolValue == false, v.rec["private"]?.boolValue != true else { return false }
        if let p = v.rec["project"]?.stringValue, let list = book.now[p] {
            return list.rec["locked"]?.boolValue == false && list.rec["private"]?.boolValue != true
        }
        return true
    }

    /// The time a record was set for, as it keeps it: due, else remind, else start; nil when it has none.
    static func whenOf(_ rec: [String: JSONValue]) -> String? {
        for k in ["due", "remind", "start"] {
            if let v = rec[k]?.stringValue, !v.trimmingCharacters(in: .whitespaces).isEmpty { return v }
        }
        return nil
    }

    // MARK: lists

    func lists() async throws -> [ListGroup]? {
        PhoneLists.groups(book: try store.book())
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

/// One at a time, in the order they asked: a waiting caller is resumed when the one before it leaves.
final class Turn {
    private let lock = NSLock()
    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            lock.lock()
            if busy { waiting.append(next); lock.unlock() } else { busy = true; lock.unlock(); next.resume() }
        }
    }

    func leave() {
        lock.lock()
        if waiting.isEmpty { busy = false; lock.unlock() } else { let next = waiting.removeFirst(); lock.unlock(); next.resume() }
    }
}
