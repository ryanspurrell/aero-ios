import Foundation
import SwiftUI

/// The one place the app's records live. Every change goes through the pure rules in Model/ (each cites FieldSample.lean). The records are kept in
/// one file on this device (completely protected, left out of backups) and never leave it: the Field target has no network code and asks for no
/// location. See `FieldPersistence`.
final class FieldStore: ObservableObject {
    @Published private(set) var data: FieldData
    let method: Method
    private let persistence: FieldPersistence?
    private let clock: () -> Int

    init(method: Method = .method7400, persistence: FieldPersistence? = nil, clock: @escaping () -> Int = FieldClock.now) {
        self.method = method
        self.persistence = persistence
        self.clock = clock
        self.data = persistence?.load() ?? FieldData()
    }

    /// The flow a planned sample is given until the person starts the pump and measures its flow before: 2 L/min, the Lean file's example
    /// (picked, not grounded).
    static let plannedFlow: Rat = 2

    var now: Int { clock() }
    var practice: Bool { data.practice }

    private func change(_ f: (inout FieldData) -> Void) {
        var d = data
        f(&d)
        data = d
        persistence?.save(d)
    }

    // MARK: pumps on the board (Part D)

    /// Adds a pump started now (or at `start`). The new sample's id is above every id in the run, so ids stay distinct (`add_keeps_distinct`) and
    /// no other sample's state changes (`add_independent`).
    @discardableResult
    func addPump(place: String, pump: Int, before: Rat, height: Int? = nil, start: Int? = nil) -> Int {
        let id = freshId(data.run)
        let s = Sample(id: id, pump: pump, place: place, start: start ?? now, stop: nil, before: before, after: nil, height: height)
        change { if let r = adding($0.run, s) { $0.run = r } }
        return id
    }

    /// Stops the pump now. The stop is never put before the start by the app (a stop typed by hand in the editor can be, and then the sample names
    /// `timesOrder`).
    func stop(_ id: Int) {
        let t = now
        change { d in
            let started = d.run.first(where: { $0.id == id })?.start ?? 0
            d.run = stopAt(d.run, id, max(t, started))
        }
    }

    func setAfter(_ id: Int, _ flow: Rat) { change { $0.run = Field.setAfter($0.run, id, flow) } }

    /// Replaces the other fields of a sample; the id stays (`edit_independent`, `edit_ids`).
    func update(_ s: Sample) {
        change { d in d.run = edit(d.run, s.id) { _ in s } }
    }

    /// Removes a pump. The Lean file has no theorem for removal; what holds by construction is that the other samples are the same values, so
    /// their states are the same.
    func removePump(_ id: Int) { change { $0.run.removeAll { $0.id == id } } }

    func state(of s: Sample) -> SampleState { Field.state(method, s) }

    func nextPumpNumber() -> Int { (data.run.map(\.pump).max() ?? 0) + 1 }

    // MARK: the trip (Part F2)

    var toolReaches: Tools { data.tools.map(\.reach) }

    func addPlanned(place: String, height: Int?, flow: Rat) {
        let s = Sample(id: freshId(data.plan), pump: (data.plan.map(\.pump).max() ?? 0) + 1, place: place, start: 0, stop: nil, before: flow, after: nil, height: height)
        change { if let r = adding($0.plan, s) { $0.plan = r } }
    }

    func setPlannedHeight(_ id: Int, _ h: Int?) { change { d in d.plan = edit(d.plan, id) { var s = $0; s.height = h; return s } } }
    func removePlanned(_ id: Int) { change { $0.plan.removeAll { $0.id == id } } }

    func addTool(name: String, reach: Int?) {
        change { $0.tools.append(ToolEntry(id: ($0.tools.map(\.id).max() ?? 0) + 1, name: name, reach: reach)) }
    }
    func setToolReach(_ id: Int, _ reach: Int?) { change { d in if let i = d.tools.firstIndex(where: { $0.id == id }) { d.tools[i].reach = reach } } }
    func removeTool(_ id: Int) { change { $0.tools.removeAll { $0.id == id } } }

    /// A planned sample becomes a running pump on the board, started now, carrying its place, planned flow and height.
    func startPlanned(_ id: Int) {
        guard let p = data.plan.first(where: { $0.id == id }) else { return }
        addPump(place: p.place, pump: nextPumpNumber(), before: p.before, height: p.height)
        removePlanned(id)
    }

    // MARK: custody (Part F)

    func person(named name: String) -> Int {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let p = data.people.first(where: { $0.name == n }) { return p.id }
        let id = (data.people.map(\.id).max() ?? 0) + 1
        change { $0.people.append(Person(id: id, name: n.isEmpty ? "Person \(id)" : n)) }
        return id
    }

    /// Adds a handover only if it follows the last one (`valid_append`). The problem is returned in words' terms and nothing is changed.
    @discardableResult
    func addHandover(_ h: Handover) -> LinkProblem? {
        if let p = linkProblem(after: data.handovers.last, h) { return p }
        change { $0.handovers = appending($0.handovers, h) ?? $0.handovers }
        return nil
    }

    func removeLastHandover() { change { if !$0.handovers.isEmpty { $0.handovers.removeLast() } } }

    func sheet() -> String {
        FieldSheet.text(method: method, run: data.run, handovers: data.handovers, people: data.people, practice: data.practice, generated: now)
    }

    // MARK: tickets and answers

    @discardableResult
    func keepTicket(kind: TicketKind, screen: String, step: String, what: String) -> Ticket {
        let t = Ticket(id: (data.tickets.map(\.id).max() ?? 0) + 1, kind: kind, screen: screen, step: step, what: what, to: data.owner, practice: data.practice, made: now)
        change { $0.tickets.append(t) }
        return t
    }
    func removeTicket(_ id: Int) { change { $0.tickets.removeAll { $0.id == id } } }

    func answer(situation: String, _ a: Four, note: String) {
        change { d in
            d.answers.removeAll { $0.situation == situation }
            d.answers.append(SituationAnswer(situation: situation, answer: a, note: note))
        }
    }

    // MARK: settings

    func setPractice(_ on: Bool) { change { $0.practice = on } }
    func setOwner(_ name: String) { change { $0.owner = name.trimmingCharacters(in: .whitespaces) } }

    /// Erases every record on this device at once.
    func eraseEverything() {
        change { $0 = FieldData(practice: true) }
        persistence?.erase()
    }

    // MARK: practice example

    /// Fills the board, the trip and the chain with a stand-in example (Site A, Building 1): a running pump, one waiting for its flow after, one that
    /// counts, one that is short. Stand-in data only, so nothing real has to be typed.
    func loadExample() {
        let t = now
        change { d in
            d.practice = true
            d.run = [
                Sample(id: 4, pump: 4, place: "Building 1, Room 103", start: t - 400, stop: t - 300, before: 2, after: 2, height: nil),
                Sample(id: 3, pump: 3, place: "Building 1, Room 102", start: t - 400, stop: t - 200, before: 2, after: 2, height: nil),
                Sample(id: 2, pump: 2, place: "Building 1, Room 101", start: t - 300, stop: t - 100, before: 2, after: nil, height: nil),
                Sample(id: 1, pump: 1, place: "Building 1, Attic", start: t - 90, stop: nil, before: 2, after: nil, height: 310),
            ]
            d.plan = Situations.ladderTrip.plan
            d.tools = Situations.ladderTrip.scenarios[0].tools
            d.people = [Person(id: 1, name: "Person 1"), Person(id: 2, name: "Person 2"), Person(id: 3, name: "Person 3")]
            d.handovers = [Handover(giver: 1, taker: 2, time: t - 60), Handover(giver: 2, taker: 3, time: t - 30)]
        }
    }
}

/// Stand-in names for a practice copy: the sheet's places, so nothing real has to be typed.
enum StandIn {
    static let places = ["Site A, Building 1, Room 101", "Site A, Building 1, Room 205", "Site A, Building 2, Attic", "Site B, Building 1, Room 12", "Site B, Building 3, Basement"]
    static func place(_ n: Int) -> String { places[(max(n, 1) - 1) % places.count] }
}

/// The one file. Complete file protection, no backup, atomic writes. If it cannot be read the app starts empty rather than failing.
final class FieldPersistence {
    let url: URL
    init(url: URL) { self.url = url }

    static func standard() -> FieldPersistence {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return FieldPersistence(url: dir.appendingPathComponent("field-records.json"))
    }

    func load() -> FieldData? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(FieldData.self, from: d)
    }

    func save(_ data: FieldData) {
        guard let d = try? JSONEncoder().encode(data) else { return }
        try? d.write(to: url, options: [.atomic, .completeFileProtection])
        var u = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? u.setResourceValues(values)
    }

    func erase() { try? FileManager.default.removeItem(at: url) }
}
