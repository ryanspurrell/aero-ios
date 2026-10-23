import XCTest
@testable import Aero

/// Find out why in the app: the flow against Systems/FailureDiagnosis.lean, Doctor's own data file, and the phone asking Doctor through Aero
/// (answers made by fingus_core_doctor_diagnose.py: tools/live_shapes.py). Invented data only.
@MainActor
final class FailureDiagnosisTests: XCTestCase {
    private var saved: URL?
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        saved = AppInfo.address
        AppInfo.address = URL(string: "https://aero.invalid")
        LiveStub.reset()
        ConnectionMonitor.shared.startAgain()
        defaults = UserDefaults(suiteName: "fingus-diagnosis-tests")
        defaults.removePersistentDomain(forName: "fingus-diagnosis-tests")
    }

    override func tearDown() {
        AppInfo.address = saved
        LiveStub.reset()
        defaults.removePersistentDomain(forName: "fingus-diagnosis-tests")
        super.tearDown()
    }

    private func data() throws -> DoctorFailures { try XCTUnwrap(DoctorFailures.load(), "Doctor's data file is not in the app") }

    private func fixture(_ name: String) throws -> Data { try LiveStub.fixture(name, in: Bundle(for: FailureDiagnosisTests.self)) }

    private func runner(online: Bool = true) throws -> DiagnosisRunner {
        DiagnosisRunner(data: try data(), api: DoctorAPI(session: LiveStub.session()), online: { online }, defaults: defaults)
    }

    // MARK: the flow (FailureDiagnosis.lean)

    func testDoctorsDataIsInTheApp() throws {
        let d = try data()
        XCTAssertEqual(Set(d.failures.keys), ["pc_unreachable", "network", "copy", "play", "device_permission", "other"])
    }

    func testAFailingCheckIsTheAnswerAndNothingIsAsked() throws {          // failing_check_asks_nothing
        let d = try XCTUnwrap(try data().failures["pc_unreachable"])
        let r: [String: DiagRes] = ["device_online": .holds, "pc_answers": .fails, "core_answers": .unknown, "doctor_findings": .unknown]
        XCTAssertEqual(FailureDiagnosis.shown(d, r, [:]), .cause(check: "pc_answers", text: "Your PC isn't answering. Check it's on and online."))
        XCTAssertEqual(FailureDiagnosis.shown(d, r.merging(["device_online": .fails]) { $1 }, [:]),
                       .cause(check: "device_online", text: "This device is offline. Connect it to the internet."))
    }

    func testAQuestionIsAskedOnlyWhenNoCheckSettlesIt() throws {          // asked_only_if_unsettled
        let d = try XCTUnwrap(try data().failures["pc_unreachable"])
        let unknown: [String: DiagRes] = ["device_online": .holds, "pc_answers": .unknown, "core_answers": .unknown, "doctor_findings": .unknown]
        XCTAssertEqual(FailureDiagnosis.asked(d, unknown), "pc_on")
        XCTAssertEqual(FailureDiagnosis.shown(d, unknown, [:]), .asking(DiagQuestion(id: "pc_on", text: "Is your PC on?")))
        var settled = unknown
        settled["pc_answers"] = .holds
        XCTAssertNil(FailureDiagnosis.asked(d, settled))
        XCTAssertEqual(FailureDiagnosis.shown(d, settled, [:]), .allHold(text: "Everything checks out now. Do it again."))
    }

    func testEveryQuestionOffersNotSureAndItIsRecordedAndStaysOpen() {          // notSure_in_choices, notSure_recorded_and_open, decided_recorded_and_closed
        XCTAssertTrue(DiagAns.allCases.contains(.notSure))
        let log = FailureDiagnosis.answer(.init(), "pc_on", .notSure)
        XCTAssertEqual(log.answers, [["pc_on", "notSure"]])
        XCTAssertEqual(log.open, ["pc_on"])
        XCTAssertEqual(FailureDiagnosis.answer(log, "pc_on", .notSure).open, ["pc_on"])
        let closed = FailureDiagnosis.answer(log, "pc_on", .yes)
        XCTAssertEqual(closed.open, [])
        XCTAssertEqual(closed.answers.first, ["pc_on", "yes"])
        // an answer never closes another question (answer_keeps_other_open)
        XCTAssertEqual(FailureDiagnosis.answer(log, "other_q", .yes).open, ["pc_on"])
    }

    func testWhatIsShownDependsOnlyOnThisFailuresOwnChecks() throws {          // shown_congr
        let d = try XCTUnwrap(try data().failures["copy"])
        XCTAssertTrue(d.checks.isEmpty)
        for r in [DiagRes.holds, .fails, .unknown] {
            XCTAssertEqual(FailureDiagnosis.shown(d, ["pc_answers": r, "device_online": r], [:]), .noChecks(text: "Doctor has no checks for this yet."))
        }
    }

    // MARK: asking, with the PC answering and without

    func testDoctorOnThePCAnswersWhenItAnswers() async throws {
        LiveStub.json("GET /doctor/ping", #"{"ok": true}"#)
        let body = try fixture("doctor_diagnose_cause.json")
        LiveStub.route("POST /doctor/diagnose") { _ in LiveStub.Answer(status: 200, body: body) }
        let r = try runner()
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .cause(check: "doctor_findings", text: "Doctor has a problem waiting. Open System health."))
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .yes)          // the phone reached it and the PC says its Core answers
    }

    func testNothingWaitingOnThePCSaysSo() async throws {
        LiveStub.json("GET /doctor/ping", #"{"ok": true}"#)
        let body = try fixture("doctor_diagnose_allhold.json")
        LiveStub.route("POST /doctor/diagnose") { _ in LiveStub.Answer(status: 200, body: body) }
        let r = try runner()
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .allHold(text: "Everything checks out now. Do it again."))
    }

    func testWithThePCSilentTheSameFlowRunsOnThePhone() async throws {
        LiveStub.route("GET /doctor/ping") { _ in LiveStub.Answer(status: 0, body: Data(), failure: .cannotConnectToHost) }
        let r = try runner()
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .cause(check: "pc_answers", text: "Your PC isn't answering. Check it's on and online."))
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .no)
        XCTAssertFalse(LiveStub.seen.contains("POST /doctor/diagnose"))
    }

    func testAnOfflinePhoneNeedsNoPCToSayWhy() async throws {
        let r = try runner(online: false)
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .cause(check: "device_online", text: "This device is offline. Connect it to the internet."))
        XCTAssertTrue(LiveStub.seen.isEmpty)
    }

    func testATunnelWithNothingBehindItIsNotAnAnswer() async throws {
        LiveStub.route("GET /doctor/ping") { _ in LiveStub.Answer(status: 502, body: Data("<html>bad gateway</html>".utf8), type: "text/html") }
        let r = try runner()
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .cause(check: "pc_answers", text: "Your PC isn't answering. Check it's on and online."))
    }

    func testAnUnknownPCIsAskedAndNotSureStaysOpen() async throws {
        LiveStub.route("GET /doctor/ping") { _ in LiveStub.Answer(status: 0, body: Data(), failure: .timedOut) }
        let r = try runner()
        await r.run(failure: "pc_unreachable")
        XCTAssertEqual(r.shown, .asking(DiagQuestion(id: "pc_on", text: "Is your PC on?")))
        await r.run(failure: "pc_unreachable", answer: .notSure)
        XCTAssertEqual(r.shown, .stillOpen(DiagQuestion(id: "pc_on", text: "Is your PC on?"), text: "Not sure is saved. Check whether your PC is on."))
        XCTAssertEqual(r.log.open, ["pc_on"])
        await r.run(failure: "pc_unreachable", answer: .no)
        XCTAssertEqual(r.shown, .answered(question: "pc_on", answer: .no, text: "Turn your PC on."))
        XCTAssertEqual(r.log.open, [])
    }

    func testAFailureDoctorHasNoDataForSaysSo() async throws {
        let r = try runner()
        await r.run(failure: "something_new")
        XCTAssertEqual(r.shown, .noChecks(text: "Doctor has no checks for this yet."))
    }
}
