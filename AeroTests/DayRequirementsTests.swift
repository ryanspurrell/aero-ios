import XCTest
@testable import Aero

/// The day's requirements as the phone draws them (rebuild__bottom_up_organizer.md, "Answers so far"; the same Python makes the answer, so
/// these read an answer in its shape): a thing put off is on its new day marked and its old day says where it went, quietly; a thing due
/// one day and done another is on both, marked; things at the same time have no first. Not run when written (no Mac at hand).
final class DayRequirementsTests: XCTestCase {
    private func decode(_ json: String) throws -> DayAnswer {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(DayAnswer.self, from: Data(json.utf8))
    }

    private func item(_ extra: String) -> String {
        "{\"kind\":\"item\",\"source\":\"organizer\",\"type\":\"task\",\"time_text\":\"4:00 PM\",\"time\":\"16:00\",\"color\":\"accent\",\"icon\":\"tasks\"," + extra + "}"
    }

    private func day(rows: [String], simple: String = "") throws -> DayAnswer {
        try decode("""
        {"date":"2026-10-16","label":"Tomorrow","date_text":"Friday 16 October","is_today":false,"prev":"2026-10-15","next":"2026-10-17",
         "rows":[\(rows.joined(separator: ","))],"anytime":[],
         "simple":{"greeting":"Hello","clock":"","next":null,"behind":[],"later":[],"did":[],"none":""\(simple)}}
        """)
    }

    func testAMovedRowIsQuietSaysWhereItWentAndOpensTheNewDay() throws {
        let d = try day(rows: [item("\"id\":\"a1\",\"title\":\"Renew the pass\",\"state\":\"moved\",\"mark_text\":\"Moved to Friday 4:00 PM\",\"moved_to\":{\"date\":\"2026-10-16\",\"time\":\"16:00\",\"text\":\"Friday 4:00 PM\"}")])
        let p = Pointer(d.rows[0])
        XCTAssertTrue(p.quiet)
        XCTAssertEqual(p.meta, "Moved to Friday 4:00 PM")
        XCTAssertEqual(p.open?.app, Pointer.dayApp, "it opens the new place: the day it was moved to")
        XCTAssertEqual(p.open?.id, "2026-10-16")
    }

    func testTheNewPlaceShowsTheTaskAsNormalWithASmallMark() throws {
        let d = try day(rows: [item("\"id\":\"a1\",\"title\":\"Renew the pass\",\"state\":\"open\",\"mark_text\":\"Moved from Thursday\",\"until\":\"in 6 h\"")])
        let p = Pointer(d.rows[0])
        XCTAssertFalse(p.quiet)
        XCTAssertEqual(p.meta, "in 6 h \u{00B7} Moved from Thursday")
    }

    func testDueOneDayDoneAnotherIsMarkedOnBothDays() throws {
        let thursday = try day(rows: [item("\"id\":\"b1\",\"title\":\"Pay the bill\",\"state\":\"was_due\",\"mark_text\":\"Done later, on Saturday\"")])
        XCTAssertTrue(Pointer(thursday.rows[0]).quiet)
        XCTAssertEqual(Pointer(thursday.rows[0]).meta, "Done later, on Saturday")
        XCTAssertFalse(Pointer(thursday.rows[0]).done, "it was only due here, it is not done here")
        let saturday = try day(rows: [item("\"id\":\"b1\",\"title\":\"Pay the bill\",\"state\":\"done\",\"done_at_text\":\"10:00 AM\",\"mark_text\":\"Was due Thursday\"")])
        XCTAssertTrue(Pointer(saturday.rows[0]).done)
        XCTAssertEqual(Pointer(saturday.rows[0]).meta, "Done at 10:00 AM \u{00B7} Was due Thursday")
    }

    func testAnOlderAnswerWithoutTheNewFieldsStillReads() throws {
        let d = try day(rows: [item("\"id\":\"c1\",\"title\":\"Old\",\"state\":\"open\"")])
        XCTAssertNil(d.rows[0].markText)
        XCTAssertNil(d.simple.nexts)
        XCTAssertFalse(Pointer(d.rows[0]).quiet)
    }

    func testThingsAtTheSameTimeHaveNoFirstAndTheReaderOrdersThem() throws {
        let nextJSON = { (id: String) in "{\"id\":\"\(id)\",\"title\":\"\(id)\",\"open\":{\"app\":\"organizer\",\"id\":\"\(id)\"},\"line\":\"At 3:00 PM, in 1 hour\",\"button\":\"Done\"}" }
        let d = try day(rows: [item("\"id\":\"b\",\"title\":\"b\",\"state\":\"open\""), item("\"id\":\"a\",\"title\":\"a\",\"state\":\"open\""),
                               item("\"id\":\"z\",\"time\":\"18:00\",\"title\":\"z\",\"state\":\"open\"")],
                        simple: ",\"nexts\":[\(nextJSON("b")),\(nextJSON("a"))]")
        XCTAssertEqual(d.rows.map(\.id), ["b", "a", "z"], "as Organizer made them, not by title")
        XCTAssertEqual(TieOrder.arrange(d.rows, rightToLeft: false).map(\.id), ["b", "a", "z"])
        XCTAssertEqual(TieOrder.arrange(d.rows, rightToLeft: true).map(\.id), ["a", "b", "z"], "a right-to-left reader reads the tie the other way; z is alone")
        XCTAssertEqual(TieOrder.firstNext(d.simple, rightToLeft: false), "b")
        XCTAssertEqual(TieOrder.firstNext(d.simple, rightToLeft: true), "a")
    }

    // MARK: done is an observation that accumulates

    /// Not run when written. A task completed twice, on two days of the phone's own clock, keeps both: `done_ats` has two times.
    @MainActor
    func testCompletingTwiceKeepsBothDoneObservationsAndEditingToDoneRecordsOne() async throws {
        var now = Date()
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: CannedQuickAddReader(), clock: { now })
        try await phone.send("add", ["title": .string("Water the ferns")])
        let id = try phone.store.book().now.keys.first!
        try await phone.send("complete", ["id": .string(id)])
        now = now.addingTimeInterval(2 * 86400)
        try await phone.send("complete", ["id": .string(id)])
        XCTAssertEqual(try phone.store.book().now[id]?.rec["done_ats"]?.arrayValue?.count, 2, "the second does not replace the first")
        try await phone.send("add", ["title": .string("Mail the form")])
        let other = try phone.store.book().now.keys.first { $0 != id }!
        try await phone.send("update", ["id": .string(other), "status": .string("done")])
        XCTAssertNotNil(try phone.store.book().now[other]?.rec["done_at"], "edited to done: it has the time it was done")
        XCTAssertEqual(try phone.store.book().now[other]?.rec["done_ats"]?.arrayValue?.count, 1)
    }

    /// Not run when written. A due-day row of a task moved to an earlier day that has passed says both, and is quiet.
    func testAPassedEarlyDeferralDueRowSaysBoth() throws {
        let d = try day(rows: [item("\"id\":\"e1\",\"title\":\"Hand in the form\",\"state\":\"moved\",\"mark_text\":\"Due Friday; moved to Wednesday 4:00 PM\",\"moved_to\":{\"date\":\"2026-10-14\",\"time\":\"16:00\",\"text\":\"Wednesday 4:00 PM\"}")])
        let p = Pointer(d.rows[0])
        XCTAssertTrue(p.quiet)
        XCTAssertEqual(p.meta, "Due Friday; moved to Wednesday 4:00 PM")
        XCTAssertEqual(p.open?.id, "2026-10-14")
    }
}
