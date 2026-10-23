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
