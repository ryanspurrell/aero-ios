import SwiftUI

/// The state behind the day, week, month and year: one reference date held across the four (the owner, 2026-10-15), the answer Organizer last
/// gave, and the changes a person makes in place. Organizer is asked every time; nothing is kept here that it said.
@MainActor
final class OrganizerDayStore: ObservableObject {
    @Published private(set) var answer: CalendarAnswer?
    @Published private(set) var failure: String?
    /// Doctor's id of the kind of failure the line is about, for Find out why.
    @Published private(set) var failureDiagnosis = "other"
    @Published var span: CalendarSpan = .day
    /// "YYYY-MM-DD"; empty is today (Organizer says which day that is).
    @Published private(set) var date: String = ""
    @Published private(set) var helpers: [String] = []
    /// The open things by list, for the Lists tab; nil when this backend does not hold them (the PC's lists open in the web view).
    @Published private(set) var lists: [ListGroup]?
    /// The Lists tab is the one showing (it is not a span of the calendar; the held date waits behind it).
    @Published private(set) var showLists = false
    /// The views a day was opened from, so Back zooms out to where the person was.
    private(set) var trail: [CalendarSpan] = []

    private let api: OrganizerBackend

    /// The PC when one is set up, otherwise the phone's own records; the views do not know which.
    init(backend: OrganizerBackend = OrganizerBackends.current()) {
        self.api = backend
        if DemoMode.isOn, let s = DemoMode.screen { span = s }
        if DemoMode.isOn { date = DemoMode.heldDate; showLists = DemoMode.showListsTab }
    }

    var backend: OrganizerBackend { api }

    var tab: DayTab { showLists ? .lists : DayTab(span: span) }

    /// The underline tabs: a span is a move in view with the date held; Lists shows the lists and keeps the date.
    func select(_ tab: DayTab) async {
        if let s = tab.span {
            showLists = false
            await move(span: s)
        } else {
            showLists = true
            await load()
        }
    }

    var backendKind: BackendKind { api.kind }

    func load() async {
        do {
            let got = try await api.calendar(span: span, date: date)
            answer = got
            date = got.date
            failure = nil
        } catch {
            // the one shape: what was being done, which step stopped (the key under it says what can be done now)
            let line = StopWords.line(doing: "Showing your day", backend: api.kind, error: error)
            failure = line.text
            failureDiagnosis = line.diagnosis
        }
        lists = try? await api.lists()
        if answer?.mode == .simple { helpers = await api.helperNames() }
    }

    /// A move in time (same view) or in view (the zoom). The zoom is ChatGPT's suggestion, accepted by the owner; the views animate it with
    /// matchedGeometryEffect on the reference date's element.
    func move(span to: CalendarSpan? = nil, date newDate: String? = nil) async {
        showLists = false
        if let to, to != span {
            if to == .day { trail.append(span) } else { trail.removeAll() }
            span = to
        }
        if let newDate { date = newDate }
        await load()
    }

    /// One step in or out of the zoom, by pinch (the tabs are the tap way).
    func zoom(by step: Int) async {
        let order = CalendarSpan.zoomOrder
        guard let at = order.firstIndex(of: span), order.indices.contains(at + step) else { return }
        await move(span: order[at + step])
    }

    /// Back: a day opened from a week, month or year zooms out to it. False when there is nothing to go back to.
    func back() async -> Bool {
        guard span == .day, let was = trail.popLast() else { return false }
        span = was
        await load()
        return true
    }

    /// A question's choice: the answer is recorded where it was given and stays on screen (the view keeps the chosen one marked); the
    /// day is read again only on a later load.
    func choose(_ choice: QuestionChoice) async -> Bool {
        do { try await api.apply(choice.answer); return true } catch { fail("Saving your answer", error); return false }
    }

    func setDone(_ id: String, done: Bool, occurrence: String? = nil, presented: JSONValue? = nil, rev: String? = nil) async -> Bool {
        var args: [String: JSONValue] = ["id": .string(id)]
        if done, let rev, !rev.isEmpty { args["rev"] = .string(rev) }
        if done, let occurrence, !occurrence.isEmpty { args["occurrence"] = .string(occurrence) }
        if done, let presented { args["presented"] = presented }
        do { try await api.send(done ? "complete" : "reopen", args); return true }
        catch { fail(done ? "Marking it done" : "Reopening it", error); return false }
    }

    /// Skip: records that she skipped it, dated; nothing is deleted and it can be done after (both are then kept and shown as both).
    func skip(_ id: String, occurrence: String? = nil, presented: JSONValue? = nil, rev: String? = nil) async -> Bool {
        var args: [String: JSONValue] = ["id": .string(id)]
        if let rev, !rev.isEmpty { args["rev"] = .string(rev) }
        if let occurrence, !occurrence.isEmpty { args["occurrence"] = .string(occurrence) }
        if let presented { args["presented"] = presented }
        do { try await api.send("skip", args); return true }
        catch { fail("Skipping it", error); return false }
    }

    func askForHelp() async -> Bool {
        do { try await api.send("help_ask"); return true } catch { fail("Asking for help", error); return false }
    }

    /// A change that stopped, in the one shape (it used to show the error's own words, which for a decode were not words at all).
    private func fail(_ doing: String, _ error: Error) {
        let line = StopWords.line(doing: doing, backend: api.kind, error: error)
        failure = line.text
        failureDiagnosis = line.diagnosis
    }
}
