import Foundation

/// A launch for looking at the phone's own Organizer with invented data and no PC, used by the build's simulator run:
///   -aero-demo phone                 the phone store is emptied, filled with invented things for today, and used
///   -aero-demo-quickadd "<a line>"   then that line is typed into the box, as a person would, and its question (if any) is asked
/// Reports go to the app's Documents folder for the run to collect: demo-day.json, demo-quickadd.json, demo-modules.txt.
/// Nothing here runs unless the launch argument is given.
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "aero-demo") == "phone" }
    static var quickAddLine: String? { UserDefaults.standard.string(forKey: "aero-demo-quickadd") }
    private static var quickAddDone = false

    private static func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func write(_ name: String, _ object: Any) {
        let url = documents().appendingPathComponent(name)
        if let text = object as? String { try? text.write(to: url, atomically: true, encoding: .utf8); return }
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    /// Fill the phone store with invented things around today, once, before any screen asks for the day.
    static func prepare() async {
        guard isOn else { return }
        let phone = OrganizerBackends.phone
        let cal = Calendar.current
        let now = Date()
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0, timeless: Bool = false) -> String {
            let day = cal.date(byAdding: .day, value: dayOffset, to: now)!
            let c = cal.dateComponents([.year, .month, .day], from: day)
            let date = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
            return timeless ? date : date + String(format: " %02d:%02d", hour, minute)
        }
        func task(_ title: String, _ fields: [String: JSONValue] = [:]) -> [String: JSONValue] {
            let base: [String: JSONValue] = ["type": .string("task"), "title": .string(title), "status": .string("open"), "attention": .string("inbox"),
                                              "locked": .bool(false), "changed": .string(at(0, 7)), "basis": .object(["status": .string("said")])]
            return base.merging(fields) { _, new in new }
        }
        let soon = cal.date(byAdding: .minute, value: 90, to: now)!
        let soonText = String(format: "%04d-%02d-%02d %02d:%02d", cal.component(.year, from: soon), cal.component(.month, from: soon), cal.component(.day, from: soon),
                              cal.component(.hour, from: soon), cal.component(.minute, from: soon))
        let seeds: [([String: JSONValue], String)] = [
            (task("Take pills", ["status": .string("done"), "remind": .string(at(0, 8)), "due": .string(at(0, 8)), "done_at": .string(at(0, 8, 5))]), "done"),
            (task("Call the bank", ["due": .string(at(0, 10, 30)), "remind": .string(at(0, 10, 30))]), "added"),
            (task("Dentist (invented)", ["due": .string(soonText), "remind": .string(soonText)]), "added"),
            (task("Water the plants", ["due": .string(at(0, 21)), "remind": .string(at(0, 21))]), "added"),
            (task("Return the drill", ["due": .string(at(0, 0, timeless: true))]), "added"),
            (task("Pack the bag", ["due": .string(at(1, 7, 30)), "remind": .string(at(1, 7, 30))]), "added"),
            (task("Market with Sam", ["due": .string(at(3, 10)), "remind": .string(at(3, 10))]), "added"),
            (task("Bins out", ["repeat": .string("FREQ=WEEKLY;BYDAY=TU"), "start": .string(at(0, 19))]), "added"),
        ]
        for (rec, why) in seeds {
            _ = try? phone.store.put(oid: PhoneStore.newID(), rec: rec, by: PhoneOrganizer.person, why: why, replaces: nil)
        }
        await phone.refreshReminders()
        var report: [String: Any] = ["backend": phone.kind.rawValue, "install": phone.store.installID]
        do {
            let day = try await phone.calendar(span: .day, date: "")
            report["dayTitles"] = (day.day?.rows ?? []).filter { $0.kind == "item" }.map { $0.title ?? "" } + (day.day?.anytime ?? []).map { $0.title ?? "" }
            report["next"] = day.day?.simple.next?.title ?? ""
            for span in [CalendarSpan.week, .month, .year] {
                let a = try await phone.calendar(span: span, date: "")
                report["has_\(span.rawValue)"] = (a.week != nil || a.month != nil || a.year != nil)
            }
        } catch {
            report["error"] = error.localizedDescription
        }
        report["pythonStartSeconds"] = EmbeddedReader.shared.startSeconds
        write("demo-day.json", report)
    }

    /// The typed line, once, and the report of what became of it.
    static func runQuickAddIfAsked(backend: OrganizerBackend, onOutcome: @escaping (QuickAddOutcome) -> Void) async {
        guard isOn, !quickAddDone, let line = quickAddLine, !line.isEmpty else { return }
        quickAddDone = true
        var report: [String: Any] = ["line": line]
        do {
            let outcome = try await backend.quickAdd(line)
            report["title"] = outcome.title
            report["asked"] = outcome.question != nil
            report["choices"] = outcome.question?.choices.map { $0.label } ?? []
            report["likeliest"] = outcome.likeliest ?? -1
            if let book = try? OrganizerBackends.phone.store.book() {
                report["records"] = book.now.values.filter { $0.title.lowercased().contains(outcome.title.lowercased()) }
                    .map { ["title": $0.title, "install": $0.install ?? "", "by": $0.by ?? "", "readings": $0.rec["readings"] != nil] }
            }
            onOutcome(outcome)
        } catch {
            report["error"] = error.localizedDescription
        }
        write("demo-quickadd.json", report)
        if let loaded = try? await EmbeddedReader.shared.call("loaded", [:]).arrayValue {
            write("demo-modules.txt", loaded.compactMap { $0.stringValue }.joined(separator: "\n") + "\n")
        }
    }
}
