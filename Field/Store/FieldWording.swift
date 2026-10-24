import Foundation

// The words on screen, in one place. Short, plain, sentence case; a button says what tapping it does; a "no" always carries its reason
// (the Lean theorem `no_names_a_failed_check`). Calm words: "Doesn't count", not "Failed" (principles: gentle words by default).

/// What a sample's state says to the person: a headline, the reason, and the four-valued reading behind it (`toFour`).
struct StateWords: Equatable {
    var headline: String
    var detail: String
    var four: Four
    var symbol: String
    var hue: String
}

enum FieldWording {
    static func flow(_ r: Rat) -> String { r.text() + " L/min" }
    static func litres(_ r: Rat) -> String { r.text() + " L" }

    /// The state of a sample in plain words with its reason. Every number comes from the method passed in (`Method`), none is written here.
    static func words(_ m: Method, _ s: Sample) -> StateWords {
        let st = state(m, s)
        let four = toFour(st)
        switch st {
        case .counts:
            let v = s.stop.flatMap { e in s.after.map { volume(s.before, $0, monus(e, s.start)) } } ?? Rat(0)
            return StateWords(headline: "Counts", detail: "\(litres(v)) collected. Flow stayed in range.", four: four, symbol: "checkmark.circle", hue: "green")
        case .fails(let c):
            return StateWords(headline: "Doesn't count", detail: reason(m, s, c), four: four, symbol: "xmark.circle", hue: "red")
        case .notYet(.running):
            return StateWords(headline: "Still running", detail: "It can be read after you stop it.", four: four, symbol: "timer", hue: "yellow")
        case .notYet(.afterMissing):
            return StateWords(headline: "Waiting for flow after", detail: "Measure the flow, then add it.", four: four, symbol: "hourglass", hue: "yellow")
        }
    }

    /// The reason a check failed, with the numbers of this sample and the method.
    static func reason(_ m: Method, _ s: Sample, _ c: Check) -> String {
        let e = s.stop ?? s.start, a = s.after ?? s.before
        switch c {
        case .timesOrder: return "Stop time is before start time."
        case .beforeOutOfBand: return "Flow before, \(flow(s.before)), is outside \(m.lo.text()) to \(m.hi.text()) L/min."
        case .afterOutOfBand: return "Flow after, \(flow(a)), is outside \(m.lo.text()) to \(m.hi.text()) L/min."
        case .drift: return "Flow changed by \((s.before - a).magnitude.text()) L/min. At most \(m.tol.text()) is allowed."
        case .volumeShort: return "\(litres(volume(s.before, a, monus(e, s.start)))) collected. It needs \(litres(m.minVol))."
        }
    }

    static func fourWords(_ f: Four) -> String {
        switch f {
        case .yes: return "Yes"
        case .no: return "No"
        case .all: return "Partly"
        case .none: return "Can't tell"
        }
    }

    static func reachWords(_ f: Four) -> (headline: String, symbol: String) {
        switch f {
        case .yes: return ("Reached", "checkmark.circle")
        case .no: return ("Out of reach", "xmark.circle")
        case .all: return ("Partly", "circle.lefthalf.filled")
        case .none: return ("Not sure", "questionmark.circle")
        }
    }

    static func cm(_ h: Int) -> String { "\(h) cm" }

    static func kind(_ k: TicketKind) -> String {
        switch k {
        case .edgeCase: return "An edge case"
        case .addition: return "Something to add"
        case .brokenPlace: return "A place that doesn't work"
        case .look: return "The look"
        }
    }

    static func problem(_ p: LinkProblem, people: [Person]) -> String {
        switch p {
        case .giverIsNotLastTaker(let expected):
            return "The giver must be \(name(expected, people)), who took it last."
        case .timeGoesBack(let last):
            return "The time can't be before the last handover, \(FieldClock.time(last))."
        }
    }

    static func name(_ id: Int, _ people: [Person]) -> String { people.first(where: { $0.id == id })?.name ?? "Person \(id)" }
}
