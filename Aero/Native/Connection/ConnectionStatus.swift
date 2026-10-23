import Foundation

// Which place the app is using, and whether it reached it (Aryn, 2026-10-23, 5:40 am: "i think connected to pc? but i cant actually tell. should
// probably be a status somewhere"). The rules are Systems/ConnectionStatus.lean (Fingus repository, branch native-fix-server); the theorem
// names are repeated where a function below is that definition, and ConnectionStatusTests compares them on every combination.
//
// Placement (standing rules 17, 29, 30): the face draws and holds only what this phone saw. It needs nothing else: with no PC the phone's own
// reading stands alone (`phone_alone`). What the PC says of itself is Doctor's, asked through Aero (`/doctor/diagnose`).

/// The four values of an observation (FourContainment.Four): yes, no, all (told both), none (told neither).
enum Four: String, Equatable, CaseIterable {
    case yes, no, all, none

    var pos: Bool { self == .yes || self == .all }
    var neg: Bool { self == .no || self == .all }

    init(pos: Bool, neg: Bool) {
        switch (pos, neg) {
        case (true, false): self = .yes
        case (false, true): self = .no
        case (true, true): self = .all
        case (false, false): self = .none
        }
    }
}

/// What one observer saw of the place: it answered, it did not (refused, or could not be reached), or nothing has been asked yet.
enum Saw: Equatable, CaseIterable {
    case reached, refused, nothingYet

    /// Lean `Saw.reading`.
    var reading: Four {
        switch self {
        case .reached: return .yes
        case .refused: return .no
        case .nothingYet: return .none
        }
    }
}

enum ConnectionStatus {
    /// Lean `backendOf`, `backendOf_pc_iff`: the PC when an address was entered, otherwise the phone's own records.
    static func backend(hasAddress: Bool) -> BackendKind { hasAddress ? .pc : .phone }

    /// Lean `status` (NoPrivilegedFrame.infoJoin of the two readings): what the phone saw and what the PC says of itself, together. A reading
    /// nobody has made adds nothing (`status_nothingYet_right`), two that agree stay (`status_agree`), a reached and a refused read all
    /// (`status_disagree_all`, `status_all_iff`).
    static func status(_ phone: Saw, _ pc: Saw) -> Four {
        Four(pos: phone.reading.pos || pc.reading.pos, neg: phone.reading.neg || pc.reading.neg)
    }

    /// Lean `label`, `label_ne`.
    static func label(_ backend: BackendKind) -> String { backend == .phone ? "This phone" : "Your PC" }

    /// Lean `whyOffered`, `whyOffered_iff`, `whyOffered_phone_alone`: Find out why is Doctor's, a part of the PC, so it is offered only with a PC.
    static func whyOffered(hasAddress: Bool) -> Bool { hasAddress }

    /// What is shown: the reading and the time it last changed. Lean `Shown`.
    struct Shown: Equatable {
        var reading: Four
        var since: Date
    }

    /// Lean `step`, `step_same_keeps`, `step_changed_moves`, `step_since_le`, `step_reading`: the time moves only when the reading does.
    static func step(_ shown: Shown, new: Four, at time: Date) -> Shown {
        new == shown.reading ? shown : Shown(reading: new, since: time)
    }

    /// The island's words: the place, then what was seen and since when. Gentle and short; the symbol beside them does not rely on colour.
    static func words(backend: BackendKind, shown: Shown, time: (Date) -> String) -> String {
        let place = label(backend)
        switch shown.reading {
        case .yes: return "\(place) · reached since \(time(shown.since))"
        case .no: return "\(place) · not reached since \(time(shown.since))"
        case .none: return "\(place) · no answer yet"
        case .all: return "\(place) · phone and PC disagree since \(time(shown.since))"
        }
    }

    static func symbol(_ reading: Four) -> String {
        switch reading {
        case .yes: return "checkmark.circle"
        case .no: return "xmark.circle"
        case .none: return "circle.dotted"
        case .all: return "arrow.left.arrow.right.circle"
        }
    }

    static func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}

/// What this phone has seen of the place it uses, and what the PC has said of itself, kept for the island. One for the app.
@MainActor
final class ConnectionMonitor: ObservableObject {
    static let shared = ConnectionMonitor()

    @Published private(set) var shown: ConnectionStatus.Shown
    @Published private(set) var backend: BackendKind

    private var phone: Saw = .nothingYet
    private var pc: Saw = .nothingYet
    private let clock: () -> Date
    /// The address the reading is about; another one starts a new reading.
    private var address: String?

    init(clock: @escaping () -> Date = Date.init, backend: BackendKind? = nil) {
        self.clock = clock
        self.address = AppInfo.address?.absoluteString
        let kind = backend ?? ConnectionStatus.backend(hasAddress: AppInfo.address != nil)
        self.backend = kind
        self.shown = ConnectionStatus.Shown(reading: .none, since: clock())
    }

    /// A request to the place ended (or the phone's own records were read, or not). Another place than the last starts again: nothing carries
    /// over from the PC to the phone or back.
    func sawOwn(_ saw: Saw, backend kind: BackendKind) {
        if kind != backend { start(kind) }
        // the PC's word about itself was about an earlier moment once this phone sees something different
        if saw != phone { pc = .nothingYet }
        phone = saw
        refresh()
    }

    /// What the PC said of itself when asked (Doctor's `core_answers`).
    func pcSaid(_ saw: Saw) {
        guard backend == .pc else { return }
        pc = saw
        refresh()
    }

    /// Told whenever the saved settings change: only a different address starts a new reading.
    func placeChanged() {
        let now = AppInfo.address?.absoluteString
        guard now != address else { return }
        address = now
        start(ConnectionStatus.backend(hasAddress: now != nil))
    }

    /// A new reading for the place in use now: nothing seen, nothing said.
    func startAgain() { start(ConnectionStatus.backend(hasAddress: AppInfo.address != nil)) }

    private func start(_ kind: BackendKind) {
        backend = kind
        phone = .nothingYet
        pc = .nothingYet
        shown = ConnectionStatus.Shown(reading: .none, since: clock())
    }

    private func refresh() {
        shown = ConnectionStatus.step(shown, new: ConnectionStatus.status(phone, pc), at: clock())
    }

    var words: String { ConnectionStatus.words(backend: backend, shown: shown, time: ConnectionStatus.shortTime) }
}
