import SwiftUI

/// The state behind the day, week, month and year: one reference date held across the four (the owner, 2026-10-15), the answer Organizer last
/// gave, and the changes a person makes in place. Organizer is asked every time; nothing is kept here that it said.
@MainActor
final class OrganizerDayStore: ObservableObject {
    @Published private(set) var answer: CalendarAnswer?
    @Published private(set) var failure: String?
    @Published var span: CalendarSpan = .day
    /// "YYYY-MM-DD"; empty is today (Organizer says which day that is).
    @Published private(set) var date: String = ""
    @Published private(set) var helpers: [String] = []
    /// The views a day was opened from, so Back zooms out to where the person was.
    private(set) var trail: [CalendarSpan] = []

    private let api: OrganizerBackend

    /// The PC when one is set up, otherwise the phone's own records; the views do not know which.
    init(backend: OrganizerBackend = OrganizerBackends.current()) {
        self.api = backend
    }

    func load() async {
        do {
            let got = try await api.calendar(span: span, date: date)
            answer = got
            date = got.date
            failure = nil
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? "Organizer didn't answer."
        }
        if answer?.mode == .simple { helpers = await api.helperNames() }
    }

    /// A move in time (same view) or in view (the zoom). The zoom is ChatGPT's suggestion, accepted by the owner; the views animate it with
    /// matchedGeometryEffect on the reference date's element.
    func move(span to: CalendarSpan? = nil, date newDate: String? = nil) async {
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
        do { try await api.apply(choice.answer); return true } catch { failure = error.localizedDescription; return false }
    }

    func setDone(_ id: String, done: Bool) async -> Bool {
        do { try await api.send(done ? "complete" : "reopen", ["id": .string(id)]); return true }
        catch { failure = error.localizedDescription; return false }
    }

    func askForHelp() async -> Bool {
        do { try await api.send("help_ask"); return true } catch { failure = error.localizedDescription; return false }
    }
}
