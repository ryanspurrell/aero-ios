import Foundation
import Network
import WebKit

// Find out why, in the app (Aryn, 2026-10-23, 4:30-4:31 am: "yes"): a failure line says what happened and carries one key; the key opens Doctor's
// diagnosis. The flow is Systems/FailureDiagnosis.lean (Fingus repository) as the PC's fingus_core_doctor_diagnose.py and the page's block in
// aero_web.py have it; this is the same definition for the phone. The data, which failure has which checks, question and steps, is Doctor's
// own file, copied unchanged into the app (Aero/Resources/fingus_core_doctor_failures.json; tools/doctor_failures_source.txt says where from).
//
// The phone runs the checks it can (this device is online; the PC answers), asks Doctor on the PC when it answers (its own checks, a kept
// answer), and with the PC silent runs the same flow here from the phone's results alone, so a PC that does not answer still gets a cause.

/// Doctor's data file.
struct DoctorFailures: Decodable {
    struct Ask: Decodable {
        var id: String
        var text: String
        var settledBy: String?
    }
    struct Steps: Decodable {
        var cause: [String: String]
        var answered: [String: [String: String]]
        var stillOpen: [String: String]
        var allHold: String?
        var noChecks: String?
    }
    struct Failure: Decodable {
        var kind: String
        var checks: [String]
        var ask: Ask?
        var steps: Steps
    }
    var failures: [String: Failure]

    static let noChecks = "Doctor has no checks for this yet."

    static func load(from bundle: Bundle = Bundle(for: DiagnosisRunner.self)) -> DoctorFailures? {
        guard let url = bundle.url(forResource: "fingus_core_doctor_failures", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DoctorFailures.self, from: data)
    }
}

/// What a check says: it holds, it fails, or it could not be run now (Lean `Res`).
enum DiagRes: String { case holds, fails, unknown }

/// An answer to a question: yes, no, or not sure, which is the none of the four (Lean `Ans`).
enum DiagAns: String, CaseIterable { case yes, no, notSure }

struct DiagQuestion: Equatable {
    var id: String
    var text: String
}

/// What the person is shown (Lean `Shown`).
enum DiagShown: Equatable {
    case cause(check: String, text: String)
    case asking(DiagQuestion)
    case stillOpen(DiagQuestion, text: String)
    case answered(question: String, answer: DiagAns, text: String)
    case allHold(text: String)
    case noChecks(text: String)

    var text: String {
        switch self {
        case .cause(_, let t), .stillOpen(_, let t), .answered(_, _, let t), .allHold(let t), .noChecks(let t): return t
        case .asking(let q): return q.text
        }
    }

    var isStillOpen: Bool {
        if case .stillOpen = self { return true }
        return false
    }

    var question: DiagQuestion? {
        switch self {
        case .asking(let q), .stillOpen(let q, _): return q
        default: return nil
        }
    }
}

enum FailureDiagnosis {
    /// Lean `firstFail`.
    static func firstFail(_ checks: [String], _ results: [String: DiagRes]) -> String? {
        checks.first { results[$0] == .fails }
    }

    /// Lean `asked`, `asked_only_if_unsettled`: the question is asked only when there is one and no check settles it.
    static func asked(_ d: DoctorFailures.Failure, _ results: [String: DiagRes]) -> String? {
        guard let q = d.ask else { return nil }
        guard let settled = q.settledBy else { return q.id }
        return (results[settled] ?? .unknown) == .unknown ? q.id : nil
    }

    /// Lean `shown`, `failing_check_asks_nothing`, `shown_congr`: checks first, then the question, then the step that fits. Only this failure's own
    /// checks, the check that settles its question and the answer to its question decide it.
    static func shown(_ d: DoctorFailures.Failure, _ results: [String: DiagRes], _ answers: [String: DiagAns]) -> DiagShown {
        let steps = d.steps
        if let c = firstFail(d.checks, results) {
            return .cause(check: c, text: steps.cause[c] ?? DoctorFailures.noChecks)
        }
        guard let q = asked(d, results), let ask = d.ask else {
            return d.checks.isEmpty ? .noChecks(text: steps.noChecks ?? DoctorFailures.noChecks) : .allHold(text: steps.allHold ?? "")
        }
        let question = DiagQuestion(id: q, text: ask.text)
        guard let a = answers[q] else { return .asking(question) }
        if a == .notSure { return .stillOpen(question, text: steps.stillOpen[q] ?? "") }
        return .answered(question: q, answer: a, text: steps.answered[q]?[a.rawValue] ?? "")
    }

    /// What is written down: every answer in order, and the questions still open (Lean `Log`).
    struct Log: Codable, Equatable {
        var answers: [[String]] = []
        var open: [String] = []
    }

    /// Lean `answer`, `notSure_recorded_and_open`, `decided_recorded_and_closed`, `answer_keeps_other_open`: Not sure is recorded and the
    /// question stays open; Yes and No are recorded and close it.
    static func answer(_ log: Log, _ q: String, _ a: DiagAns) -> Log {
        var out = Log(answers: [[q, a.rawValue]] + log.answers, open: log.open)
        if a == .notSure {
            if !out.open.contains(q) { out.open.insert(q, at: 0) }
        } else {
            out.open = out.open.filter { $0 != q }
        }
        return out
    }
}

// MARK: asking the PC

/// The PC's side of a diagnosis, through Aero: `GET doctor/ping` (the program answers, and nothing else) and `POST doctor/diagnose`.
final class DoctorAPI {
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? ChatAPI.isolatedSession()
    }

    @MainActor
    private func prepared(_ path: String, timeout: TimeInterval) async -> URLRequest? {
        guard let base = AppInfo.address, let url = ChatAPI.url(base: base, path: path) else { return nil }
        let cookies = ChatAPI.applicable(await WKWebsiteDataStore.default().httpCookieStore.allCookies(), to: url)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// Whether the PC's program answers: any answer from it is an answer (a refusal for an account without the right too); a tunnel with nothing
    /// behind it says 5xx. A timeout is not known either way.
    func ping() async -> DiagRes {
        guard let request = await prepared("doctor/ping", timeout: 5) else { return .unknown }
        do {
            let (_, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let saw: Saw = code > 0 && code < 500 ? .reached : .refused
            await ConnectionMonitor.shared.sawOwn(saw, backend: .pc)
            return saw == .reached ? .holds : .fails
        } catch let error as URLError where error.code == .timedOut {
            return .unknown
        } catch {
            await ConnectionMonitor.shared.sawOwn(.refused, backend: .pc)
            return .fails
        }
    }

    /// Doctor's own diagnosis of one failure, from the checks this phone ran and the answer given, or nil when it did not answer.
    func diagnose(failure: String, checks: [String: DiagRes], answer: DiagAns?) async -> DiagShown? {
        guard var request = await prepared("doctor/diagnose", timeout: 15) else { return nil }
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["failure": failure, "checks": checks.mapValues(\.rawValue)]
        body["answer"] = answer?.rawValue ?? NSNull()
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let said = try? JSONDecoder().decode(Said.self, from: data) else { return nil }
        if let core = said.checks?["core_answers"] {
            await ConnectionMonitor.shared.pcSaid(core == "holds" ? .reached : core == "fails" ? .refused : .nothingYet)
        }
        return said.shown
    }

    /// Doctor's answer: `{kind, text, check, question: {id, text, choices}, q, answer, checks}` (fingus_core_doctor_diagnose.shown).
    struct Said: Decodable {
        struct Q: Decodable { var id: String; var text: String }
        var kind: String
        var text: String?
        var check: String?
        var question: Q?
        var q: String?
        var answer: String?
        var checks: [String: String]?

        var shown: DiagShown? {
            let words = text ?? ""
            switch kind {
            case "cause":
                guard let check else { return nil }
                return DiagShown.cause(check: check, text: words)
            case "asking":
                guard let question else { return nil }
                return DiagShown.asking(DiagQuestion(id: question.id, text: question.text))
            case "stillOpen":
                guard let question else { return nil }
                return DiagShown.stillOpen(DiagQuestion(id: question.id, text: question.text), text: words)
            case "answered":
                guard let q, let a = answer.flatMap(DiagAns.init(rawValue:)) else { return nil }
                return DiagShown.answered(question: q, answer: a, text: words)
            case "allHold": return DiagShown.allHold(text: words)
            case "noChecks": return DiagShown.noChecks(text: words.isEmpty ? DoctorFailures.noChecks : words)
            default: return nil
            }
        }
    }
}

/// Whether this device is online, from the system's own path monitor.
final class PathWatch: @unchecked Sendable {
    static let shared = PathWatch()
    private let monitor = NWPathMonitor()
    private(set) var online = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in self?.online = path.status == .satisfied }
        monitor.start(queue: DispatchQueue(label: "fingus.path"))
    }
}

/// One diagnosis at a time, for the sheet: the checks, Doctor when it answers, the same flow here when it does not, the kept answers.
@MainActor
final class DiagnosisRunner: ObservableObject {
    @Published private(set) var shown: DiagShown?
    @Published private(set) var checking = false

    private let data: DoctorFailures?
    private let api: DoctorAPI
    private let online: () -> Bool
    private let defaults: UserDefaults
    private static let logKey = "FingusDiagnosisLog"

    init(data: DoctorFailures? = DoctorFailures.load(), api: DoctorAPI = DoctorAPI(), online: @escaping () -> Bool = { PathWatch.shared.online },
         defaults: UserDefaults = .standard) {
        self.data = data
        self.api = api
        self.online = online
        self.defaults = defaults
    }

    /// The answers kept between visits: a Not sure stays open.
    var log: FailureDiagnosis.Log {
        guard let raw = defaults.data(forKey: Self.logKey), let log = try? JSONDecoder().decode(FailureDiagnosis.Log.self, from: raw) else { return .init() }
        return log
    }

    private func keep(_ q: String, _ a: DiagAns) {
        if let raw = try? JSONEncoder().encode(FailureDiagnosis.answer(log, q, a)) { defaults.set(raw, forKey: Self.logKey) }
    }

    /// Run the diagnosis of one failure (its id in Doctor's data), with the answer just given if there is one.
    func run(failure: String, answer: DiagAns? = nil) async {
        checking = true
        defer { checking = false }
        guard let d = data?.failures[failure] else { shown = .noChecks(text: DoctorFailures.noChecks); return }
        if let answer, let q = d.ask?.id { keep(q, answer) }
        // what this phone can check itself
        var mine: [String: DiagRes] = ["device_online": online() ? .holds : .fails, "pc_answers": .unknown]
        if mine["device_online"] == .holds { mine["pc_answers"] = await api.ping() }
        if mine["pc_answers"] == .holds, let said = await api.diagnose(failure: failure, checks: mine, answer: answer) {
            shown = said
            return
        }
        var results: [String: DiagRes] = [:]
        for c in d.checks { results[c] = mine[c] ?? .unknown }
        var answers: [String: DiagAns] = [:]
        if let answer, let q = d.ask?.id { answers[q] = answer }
        shown = FailureDiagnosis.shown(d, results, answers)
    }
}
