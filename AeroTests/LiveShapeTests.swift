import XCTest
@testable import Aero

/// How the app reads what the installed Aero answers, not what a branch of it would. The files in Fixtures/live are made by the server's own
/// code over invented data (tools/live_shapes.py). Written after 2026-10-23, 5:39 am, when the Day tab and a chat both stopped on Aryn's
/// phone with a PC that was answering.
@MainActor
final class LiveShapeTests: XCTestCase {
    private var saved: URL?

    override func setUp() {
        super.setUp()
        saved = AppInfo.address
        AppInfo.address = URL(string: "https://aero.invalid")
        LiveStub.reset()
        ConnectionMonitor.shared.startAgain()
    }

    override func tearDown() {
        AppInfo.address = saved
        LiveStub.reset()
        super.tearDown()
    }

    private func fixture(_ name: String) throws -> Data { try LiveStub.fixture(name, in: Bundle(for: LiveShapeTests.self)) }

    private func serveCalendar() throws {
        let files = ["day": try fixture("org_calendar_day.json"), "week": try fixture("org_calendar_week.json"),
                     "month": try fixture("org_calendar_month.json"), "year": try fixture("org_calendar_year.json")]
        LiveStub.route("POST /private/org") { request in
            // the page asks {name, args: {span, date}}; the answer is the span's file
            let body = request.httpBody ?? request.httpBodyStream.map { stream -> Data in
                stream.open(); defer { stream.close() }
                var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
                return data
            } ?? Data()
            let text = String(data: body, encoding: .utf8) ?? ""
            let span = ["week", "month", "year"].first { text.contains("\"\($0)\"") } ?? "day"
            return LiveStub.Answer(status: 200, body: files[span] ?? Data())
        }
    }

    // MARK: Organizer's day, week, month and year

    func testTheDayTheInstalledAeroAnswersIsRead() async throws {
        try serveCalendar()
        let answer = try await OrganizerAPI(session: LiveStub.session()).calendar(span: .day, date: "2026-10-23")
        let day = try XCTUnwrap(answer.day)
        XCTAssertEqual(day.date, "2026-10-23")
        // what has passed with nothing recorded is the installed Aero's `behind`; the app calls it unmarked
        XCTAssertEqual(day.simple.unmarked.map(\.title), ["Take pills"])
        XCTAssertEqual(day.rows.filter { $0.unmarked == true }.compactMap(\.title), ["Take pills"])
    }

    func testTheWeekMonthAndYearTheInstalledAeroAnswersAreRead() async throws {
        try serveCalendar()
        let api = OrganizerAPI(session: LiveStub.session())
        let week = try await api.calendar(span: .week, date: "2026-10-23")
        XCTAssertEqual(week.week?.days.count, 7)
        let month = try await api.calendar(span: .month, date: "2026-10-23")
        XCTAssertEqual(month.month?.cells.count, 35)
        let year = try await api.calendar(span: .year, date: "2026-10-23")
        XCTAssertEqual(year.year?.months.count, 12)
    }

    func testTheDayScreenShowsTheDayTheInstalledAeroAnswers() async throws {
        try serveCalendar()
        let store = OrganizerDayStore(backend: OrganizerAPI(session: LiveStub.session()))
        await store.load()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.answer?.day?.date, "2026-10-23")
        // the island: the PC answered, so it was reached
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .yes)
        XCTAssertEqual(ConnectionMonitor.shared.backend, .pc)
    }

    // MARK: what the Day line says when it stops

    private func dayLine(_ route: @escaping (URLRequest) -> LiveStub.Answer) async -> OrganizerDayStore {
        LiveStub.route("POST /private/org", route)
        let store = OrganizerDayStore(backend: OrganizerAPI(session: LiveStub.session()))
        await store.load()
        return store
    }

    func testADayThatCouldNotBeReachedIsToldAsThatAndTheIslandSaysNo() async {
        let store = await dayLine { _ in LiveStub.Answer(status: 0, body: Data(), failure: .cannotConnectToHost) }
        XCTAssertEqual(store.failure, "Showing your day stopped at reaching your PC.")
        XCTAssertEqual(store.failureDiagnosis, "pc_unreachable")
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .no)
    }

    func testAnEdgePageIsNotAnAnswerFromAero() async {
        let store = await dayLine { _ in LiveStub.Answer(status: 502, body: Data("<html>Bad gateway</html>".utf8), type: "text/html") }
        XCTAssertEqual(store.failure, "Showing your day stopped at reaching your PC.")
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .no)
    }

    func testAnUnhandledErrorOfAerosOwnIsAerosAnswer() async {
        let store = await dayLine { _ in LiveStub.Answer(status: 500, body: Data("500: Internal Server Error".utf8), type: "text/plain") }
        XCTAssertEqual(store.failure, "Showing your day stopped at your PC's answer.")
        XCTAssertEqual(store.failureDiagnosis, "other")
    }

    func testNotSignedInIsToldAsSigningIn() async {
        let store = await dayLine { _ in LiveStub.Answer(status: 401, body: Data(#"{"error": "sign in first"}"#.utf8)) }
        XCTAssertEqual(store.failure, "Showing your day stopped at signing in. Open Aero to sign in, then try again.")
        // Aero answered, so it was reached
        XCTAssertEqual(ConnectionMonitor.shared.shown.reading, .yes)
    }

    func testOrganizerNotRunningIsAerosOwnWordsAndIsQuoted() async {
        // aero_web.private_org answers 200 {"on": false, "error": "Organizer is not running"} while the service is down
        let store = await dayLine { _ in LiveStub.Answer(status: 200, body: Data(#"{"on": false, "error": "Organizer is not running"}"#.utf8)) }
        XCTAssertEqual(store.failure, "Showing your day stopped at your PC's answer. Your PC said \u{201C}Organizer is not running\u{201D}.")
    }

    func testAnAnswerThatIsNotTheDayIsToldAsUnreadable() async {
        let store = await dayLine { _ in LiveStub.Answer(status: 200, body: Data(#"{"on": true, "span": "day"}"#.utf8)) }
        XCTAssertEqual(store.failure, "Showing your day stopped at reading your PC's answer.")
    }

    func testThePhonesOwnDayKeepsItsLine() async {
        struct Broken: OrganizerBackend {
            var kind: BackendKind { .phone }
            func calendar(span: CalendarSpan, date: String) async throws -> CalendarAnswer { throw PhoneOrganizer.Failure.noSuchItem }
            func apply(_ change: Change) async throws {}
            func send(_ name: String, _ args: [String: JSONValue]) async throws {}
            func helperNames() async -> [String] { [] }
            func quickAdd(_ text: String) async throws -> QuickAddOutcome { QuickAddOutcome(title: text, typed: text, question: nil, likeliest: nil) }
            func keepPlain(_ question: Question) async throws {}
        }
        let store = OrganizerDayStore(backend: Broken())
        await store.load()
        XCTAssertEqual(store.failure, "Showing your day stopped at reading your records.")
    }

    // MARK: Chat

    private func serveChat() throws -> String {
        let room = String(data: try fixture("room_id.txt"), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
        LiveStub.route("GET /rooms.json") { _ in LiveStub.Answer(status: 200, body: (try? self.fixture("rooms.json")) ?? Data()) }
        LiveStub.route("GET /private/unlock/status") { _ in LiveStub.Answer(status: 200, body: Data(#"{"unlocked":false}"#.utf8)) }
        LiveStub.json("POST /devices", #"{"ok": true}"#)
        LiveStub.route("GET /rooms/\(room).json") { _ in LiveStub.Answer(status: 200, body: (try? self.fixture("room.json")) ?? Data()) }
        LiveStub.json("POST /rooms/\(room)/read", #"{"ok": true}"#)
        return room
    }

    func testAChatTheInstalledAeroAnswersIsOpened() async throws {
        _ = try serveChat()
        let session = ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: MemoryChatKeyStore())
        let list = ChatListModel(session: session)
        await list.load()
        XCTAssertNil(list.stopped)
        XCTAssertEqual(list.rooms.count, 1)
        let model = ChatRoomModel(session: session, room: try XCTUnwrap(list.rooms.first), privacy: .open)
        await model.load()
        model.leave()
        XCTAssertNil(model.stopped)
        // this phone is a new device with no seal yet, so the chat waits for its keys: the answer was read, which is what is tried here
        XCTAssertEqual(model.phase, .waitingForKeys)
        XCTAssertTrue(LiveStub.seen.contains("POST /devices"))
    }

    func testTheNinthDeviceIsToldAsTooManyDevices() async throws {
        _ = try serveChat()
        // the sentence the store raises, as the fixed Aero says it (the installed Aero says "That isn't allowed here." for it)
        let refusal = try fixture("devices_register_full_fixed.json")
        LiveStub.route("POST /devices") { _ in LiveStub.Answer(status: 400, body: refusal) }
        let session = ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: MemoryChatKeyStore())
        let list = ChatListModel(session: session)
        await list.load()
        let model = ChatRoomModel(session: session, room: try XCTUnwrap(list.rooms.first), privacy: .open)
        await model.load()
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains("devices"), said)
        XCTAssertFalse(said.contains("Aero's answer"), said)
    }
}
