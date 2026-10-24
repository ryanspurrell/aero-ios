import Foundation

/// A launch for looking at the phone's own Organizer with invented data and no PC, used by the build's simulator run:
///   -aero-demo phone                 the phone store is emptied, filled with invented things for today, and used
///   -aero-demo-quickadd "<a line>"   then that line is typed into the box, as a person would, and its question (if any) is asked
/// Reports go to the app's Documents folder for the run to collect: demo-day.json, demo-quickadd.json, demo-modules.txt.
/// Nothing here runs unless the launch argument is given.
enum DemoMode {
    static var isOn: Bool { UserDefaults.standard.string(forKey: "aero-demo") == "phone" }
    static var quickAddLine: String? { UserDefaults.standard.string(forKey: "aero-demo-quickadd") }
    /// -aero-demo-screen day|week|month|year: open the calendar on that view
    static var screen: CalendarSpan? { UserDefaults.standard.string(forKey: "aero-demo-screen").flatMap { CalendarSpan(rawValue: $0) } }
    /// -aero-demo-page shopping|you|chatlist|chat|location: open that page at launch, for the screenshots (with -aero-demo phone; location and a
    /// parts home also want -FingusPartsHome YES and an AeroServerAddress, so the part tiles that need a PC are drawn)
    static var page: String? { isOn ? UserDefaults.standard.string(forKey: "aero-demo-page") : nil }
    static var chatDemo: Bool { page == "chatlist" || page == "chat" }
    /// -aero-demo-page devices (this phone waiting), devices-approve (this phone approved, another waiting, two that may be one), devices-sheet
    /// (that waiting one open, with its parts and code) or devices-confirm (a device in use lately: asked to confirm it is not hers): the Devices
    /// screen over You.
    static var devicesDemo: Bool { page.map { ["devices", "devices-approve", "devices-sheet", "devices-confirm"].contains($0) } ?? false }
    static var devicesSheetOpen: Bool { page == "devices-sheet" || page == "devices-confirm" }
    static var devicesSheetDevice: String? { page == "devices-sheet" ? "demo-new" : page == "devices-confirm" ? "demo-web" : nil }
    static let thisDeviceID = "demo-phone"
    /// Invented devices for the picture: names are the fruit names Aero gives, ids and keys are invented. One row per device, its parts inside.
    static var oneDevices: [OneDevice] {
        let now = Date().timeIntervalSince1970
        func chat(_ id: String, _ label: String, daysAgo: Double, trusted: Bool = true) -> OneChatKey {
            let ecdh = "invented-ecdh-" + id, sign = "invented-sign-" + id
            let code = DeviceCode.code(ecdh: ecdh, sign: sign)
            return OneChatKey(device: id, label: label, added: now - daysAgo * 86_400, trusted: trusted, approvedBy: trusted ? "machine" : nil,
                              ecdh: ecdh, sign: sign, code: trusted ? nil : code, codeShown: trusted ? nil : DeviceCode.shown(code))
        }
        let phoneWaiting = page == "devices"
        let inUse = page == "devices-confirm"
        return [
            OneDevice(id: "t-phone", name: "Coconut", kind: "iPhone", this: true, waiting: phoneWaiting, seen: now, canRemove: false, whyNot: "You are using it now",
                      parts: OneParts(session: [OneSignIn(id: "s-phone", label: "Aero app", agent: "Aero app", seen: now)],
                                      chat: [chat(thisDeviceID, "iPhone (Aero app)", daysAgo: 0.1, trusted: !phoneWaiting)])),
            OneDevice(id: "t-pc", name: "Kiwi", kind: "PC", seen: now - 60, canRemove: false, whyNot: "This is the PC itself",
                      parts: OneParts(chat: [chat("demo-pc", "This PC", daysAgo: 40)], key: [OneFileKey(device: "pc-key", label: "This PC", kind: "pc", added: now - 40 * 86_400, used: now - 60)])),
            OneDevice(id: "demo-web", name: "Sapodilla", kind: "iPhone", seen: now - (inUse ? 240 : 86_400 * 3), canRemove: true,
                      info: OneInfo(seen: Int(now - (inUse ? 240 : 86_400 * 3)), confirmed: !inUse),
                      confirmFirst: inUse ? ["It was in use 4 minutes ago", "You haven't used it to confirm it is yours"] : [],
                      parts: OneParts(session: [OneSignIn(id: "s-web", label: "Safari on iPhone", agent: "Safari on iPhone", seen: now - (inUse ? 240 : 86_400 * 3))],
                                      chat: [chat("demo-web-chat", "iPhone (browser)", daysAgo: 18)])),
        ] + (phoneWaiting ? [] : [
            OneDevice(id: "demo-new", name: "Tamarind", kind: "iPhone", waiting: true, seen: now - 120, canRemove: true,
                      parts: OneParts(session: [OneSignIn(id: "s-new", label: "Safari on iPhone", agent: "Safari on iPhone", seen: now - 120)],
                                      chat: [chat("demo-new-chat", "Safari on iPhone", daysAgo: 0.02, trusted: false)])),
        ])
    }
    static var maybeSame: [OneMaybeSame] {
        page == "devices-approve" ? [OneMaybeSame(a: "demo-web", b: "demo-new", why: "Sapodilla and Tamarind used the same browser to sign in and to set up chats")] : []
    }
    /// The removal the PC would not do in one step, for the picture of the confirmation.
    static var removalAsk: OneRemovalAsk? {
        guard page == "devices-confirm", let d = oneDevices.first(where: { $0.id == "demo-web" }) else { return nil }
        return OneRemovalAsk(device: d, reasons: d.confirmFirst, info: d.info)
    }
    /// Invented chats for the picture: nothing is asked of a server and nothing is kept. The last has no name yet, so its row says when it was
    /// last used; none is called by the AI's name.
    static let chatRows: [ChatRoomRow] = [
        ChatRoomRow(id: "demo-1", name: "Weekend plans", pinned: true, unread: 2, members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")]),
        ChatRoomRow(id: "demo-2", name: "Groceries", members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")]),
        ChatRoomRow(id: "demo-4", name: nil, touched: Date().timeIntervalSince1970 - 3_600, members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")]),
        ChatRoomRow(id: "demo-5", name: "", touched: Date().timeIntervalSince1970 - 90_000, members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "qwen-demo:4b")]),
        ChatRoomRow(id: "demo-3", name: "Locked: notes", isLocked: true, members: []),
    ]
    static let chatModels = ["llama-demo:8b", "qwen-demo:4b", "auto"]
    static let chatLines: [ChatLine] = [
        ChatLine(id: "1", side: .mine, speaker: nil, text: "What is on for Saturday?", at: nil, streaming: false, unreadable: false),
        ChatLine(id: "2", side: .theirs, speaker: nil, text: "Market with Sam at 10, then the library books are due.", at: nil, streaming: false, unreadable: false),
        ChatLine(id: "3", side: .mine, speaker: nil, text: "Add a reminder to bring bags", at: nil, streaming: false, unreadable: false),
        ChatLine(id: "4", side: .theirs, speaker: nil, text: "Done: bring bags, Saturday 9:30.", at: nil, streaming: false, unreadable: false),
    ]
    /// -aero-demo-extras 1: draw Carry on and the small keys with invented content, to see the whole home of the mock
    static var showExtras: Bool { isOn && UserDefaults.standard.bool(forKey: "aero-demo-extras") }
    /// -aero-demo-tab lists: open on the Lists tab
    static var showListsTab: Bool { UserDefaults.standard.string(forKey: "aero-demo-tab") == "lists" }
    /// -aero-demo-offset 1: hold the day that many days from today (1 is tomorrow); "" is today
    static var heldDate: String {
        let n = UserDefaults.standard.integer(forKey: "aero-demo-offset")
        guard isOn, n != 0, let day = Calendar.current.date(byAdding: .day, value: n, to: Date()) else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }
    /// -aero-demo-submit "<a line>": type that line into the box and press done, once; the box's note is then on screen for the picture
    static var submitLine: String? { UserDefaults.standard.string(forKey: "aero-demo-submit") }
    private static var submitDone = false
    static func takeSubmitLine() -> String? {
        guard isOn, !submitDone, let line = submitLine, !line.isEmpty else { return nil }
        submitDone = true
        return line
    }
    private static var quickAddDone = false

    private static func documents() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func write(_ name: String, _ object: Any) {
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
        // two lists with their own colours, so the day shows more than one hue (a task takes its list's colour)
        func list(_ title: String, _ color: String, _ icon: String) -> String {
            let oid = PhoneStore.newID()
            _ = try? phone.store.put(oid: oid, rec: ["type": .string("project"), "title": .string(title), "status": .string("active"), "color": .string(color), "icon": .string(icon),
                                                      "locked": .bool(false), "changed": .string(at(0, 7))], by: PhoneOrganizer.person, why: "added", replaces: nil)
            return oid
        }
        let errands = list("Errands", "green", "cart"), health = list("Health", "orange", "heart")
        let seeds: [([String: JSONValue], String)] = [
            (task("Take pills", ["status": .string("done"), "remind": .string(at(0, 8)), "due": .string(at(0, 8)), "done_at": .string(at(0, 8, 5)), "project": .string(health)]), "done"),
            (task("Call the bank", ["due": .string(at(0, 10, 30)), "remind": .string(at(0, 10, 30))]), "added"),
            (task("Dentist (invented)", ["due": .string(soonText), "remind": .string(soonText), "project": .string(health)]), "added"),
            (task("Water the plants", ["due": .string(at(0, 21)), "remind": .string(at(0, 21))]), "added"),
            (task("Return the drill", ["due": .string(at(0, 0, timeless: true)), "project": .string(errands)]), "added"),
            (task("Pack the bag", ["due": .string(at(1, 7, 30)), "remind": .string(at(1, 7, 30))]), "added"),
            (task("Market with Sam", ["due": .string(at(3, 10)), "remind": .string(at(3, 10)), "project": .string(errands)]), "added"),
            (task("Library books", ["due": .string(at(5, 0, timeless: true)), "project": .string(errands)]), "added"),
            (task("Physio", ["due": .string(at(7, 16)), "remind": .string(at(7, 16)), "project": .string(health)]), "added"),
            (task("Call Mum", ["due": .string(at(9, 18)), "remind": .string(at(9, 18))]), "added"),
            (task("Renew pass", ["due": .string(at(12, 0, timeless: true))]), "added"),
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

/// In the demo run only: a notification centre that keeps what it is given in memory, so the simulator's permission box does not cover the
/// pictures. The real one (SystemNotifications) is used otherwise.
final class DemoNotifications: NotificationScheduling {
    private var pending: [String: DateComponents] = [:]
    func requestAuthorization() async -> Bool { true }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func remove(_ identifiers: [String]) { for i in identifiers { pending[i] = nil } }
    func schedule(identifier: String, title: String, at: DateComponents) async throws { pending[identifier] = at }
}
