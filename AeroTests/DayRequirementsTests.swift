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

    private func item(_ extra: String, timeText: String = "4:00 PM", time: String = "16:00") -> String {
        "{\"kind\":\"item\",\"source\":\"organizer\",\"type\":\"task\",\"time_text\":\"" + timeText + "\",\"time\":\"" + time + "\",\"color\":\"accent\",\"icon\":\"tasks\"," + extra + "}"
    }

    /// A task made the way the phone keeps one added by quick add (PhoneOrganizer.quickAdd), without the reader: the phone has no "add" change,
    /// so these tests keep the record directly.
    private func add(_ phone: PhoneOrganizer, _ title: String) throws {
        let rec: [String: JSONValue] = ["type": .string("task"), "title": .string(title), "status": .string("open"), "attention": .string("inbox"),
                                        "changed": .string("2026-10-16 09:00"), "basis": .object(["status": .string("said"), "by": .string(PhoneOrganizer.person)]),
                                        "locked": .bool(false)]
        _ = try phone.store.put(oid: PhoneStore.newID(), rec: rec, by: PhoneOrganizer.person, why: "added", replaces: nil)
    }

    private func day(rows: [String], simple: String = "") throws -> DayAnswer {
        try decode("""
        {"date":"2026-10-16","label":"Tomorrow","date_text":"Friday 16 October","is_today":false,"prev":"2026-10-15","next":"2026-10-17",
         "rows":[\(rows.joined(separator: ","))],"anytime":[],
         "simple":{"greeting":"Hello","clock":"","next":null,"unmarked":[],"later":[],"did":[],"none":""\(simple)}}
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
                               item("\"id\":\"z\",\"title\":\"z\",\"state\":\"open\"", timeText: "6:00 PM", time: "18:00")],
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
        try add(phone, "Water the ferns")
        let id = try phone.store.book().now.keys.first!
        try await phone.send("complete", ["id": .string(id)])
        now = now.addingTimeInterval(2 * 86400)
        try await phone.send("complete", ["id": .string(id)])
        XCTAssertEqual(try phone.store.book().now[id]?.rec["done_ats"]?.arrayValue?.count, 2, "the second does not replace the first")
        try add(phone, "Mail the form")
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

    /// Not run when written. A day with only quiet rows at no set time has nothing else; the home's rule reads them as quiet.
    func testQuietRowsAreNotSomethingElseToday() throws {
        let d = try day(rows: [])
        XCTAssertTrue(d.anytime.isEmpty)
        let quiet = try decode("""
        {"date":"2026-10-16","label":"Today","date_text":"Friday 16 October","is_today":true,"prev":"","next":"",
         "rows":[],"anytime":[\(item("\"id\":\"q\",\"title\":\"Moved\",\"state\":\"moved\",\"time_text\":\"\"" ))],
         "simple":{"greeting":"","clock":"","next":null,"unmarked":[],"later":[],"did":[],"none":""}}
        """)
        XCTAssertFalse(quiet.anytime.contains(where: { !Pointer.isQuiet($0.state) }))
    }

    /// Not run when written. No record of completion is none, not late: the words say "not marked done", nothing says late or not done.
    func testNoRecordReadsAsNotMarkedDoneNeverLate() throws {
        let d = try day(rows: [item("\"id\":\"u1\",\"title\":\"Call the bank\",\"state\":\"open\",\"unmarked\":true"),
                               item("\"id\":\"u2\",\"title\":\"Old thing\",\"state\":\"unmarked\",\"since\":\"2026-10-12\",\"unmarked\":true")])
        XCTAssertEqual(Pointer(d.rows[0]).meta, "Not marked done")
        XCTAssertEqual(Pointer(d.rows[1]).meta, "From before, not marked done")
        XCTAssertFalse((Pointer(d.rows[0]).meta ?? "").lowercased().contains("late"))
        XCTAssertFalse((Pointer(d.rows[0]).meta ?? "").contains("Not done"))
    }

    /// Not run when written. A skipped row reads Skipped, quietly; done_state is the four values and rides on the row.
    func testASkippedRowIsQuietAndCarriesTheFourValuedState() throws {
        let d = try day(rows: [item("\"id\":\"s1\",\"title\":\"Water ferns\",\"state\":\"skipped\",\"mark_text\":\"Skipped\",\"done_state\":\"no\""),
                               item("\"id\":\"s2\",\"title\":\"Wipe desk\",\"state\":\"done\",\"mark_text\":\"Done and skipped\",\"done_state\":\"all\"")])
        XCTAssertTrue(Pointer(d.rows[0]).quiet)
        XCTAssertEqual(Pointer(d.rows[0]).meta, "Skipped")
        XCTAssertEqual(d.rows[0].doneState, "no")
        XCTAssertFalse(Pointer(d.rows[1]).quiet)
        XCTAssertEqual(d.rows[1].doneState, "all")
        XCTAssertTrue((Pointer(d.rows[1]).meta ?? "").contains("Done and skipped"))
    }

    /// Not run when written. Skip records a dated observation and keeps a done as well (both kept; nothing deleted).
    @MainActor
    func testSkipThenDoneKeepsBothObservations() async throws {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: CannedQuickAddReader(), clock: { Date() })
        try add(phone, "Wipe desk")
        let id = try phone.store.book().now.keys.first!
        try await phone.send("skip", ["id": .string(id)])
        try await phone.send("complete", ["id": .string(id)])
        let rec = try phone.store.book().now[id]!.rec
        XCTAssertEqual(rec["skipped_ats"]?.arrayValue?.count, 1)
        XCTAssertEqual(rec["done_ats"]?.arrayValue?.count, 1)
    }

    /// Not run when written. The same presentation has one id; a changed size has another; the observation names layout, pointer, surface, direction.
    func testALayoutIsContentAddressedAndTheObservationSaysHowItWasShown() throws {
        var bigger = Presentation.nextCard
        bigger.pointers[0].size = "huge"
        XCTAssertEqual(Presentation.nextCard.id, Presentation.nextCard.id)
        XCTAssertNotEqual(Presentation.nextCard.id, bigger.id, "a button's size changed: another layout")
        let entry = Presentation.observation(at: "2026-10-19 10:00", presented: Presentation.presented(Presentation.nextCard, pointer: "skip"))
        XCTAssertEqual(entry.objectValue?["surface"]?.stringValue, "ios.next")
        XCTAssertEqual(entry.objectValue?["pointer"]?.stringValue, "skip")
        XCTAssertEqual(entry.objectValue?["layout"]?.stringValue, Presentation.nextCard.id)
        XCTAssertTrue(["ltr", "rtl"].contains(entry.objectValue?["direction"]?.stringValue ?? ""))
        XCTAssertEqual(Presentation.observation(at: "2026-10-19 10:00", presented: nil).stringValue, "2026-10-19 10:00", "a plain time stays plain")
        XCTAssertEqual(Presentation.obsTime(entry), "2026-10-19 10:00")
    }

    /// Not run when written. A tap records the item's pointer, the moment in her sequence, what she saw, the device and the version; never the title.
    @MainActor
    func testATapRecordsItsPointerAndMomentAndNeverTheTitle() async throws {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: CannedQuickAddReader(), clock: { Date() })
        try add(phone, "Pay Dr Chen the secret bill")
        let id = try phone.store.book().now.keys.first!
        try await phone.send("complete", ["id": .string(id), "rev": .string("stale0000000"),
                                          "presented": Presentation.presented(Presentation.nextCard, pointer: "done")])
        try await phone.send("reopen", ["id": .string(id)])
        try await phone.send("complete", ["id": .string(id), "presented": Presentation.presented(Presentation.nextCard, pointer: "done")])
        let rec = try phone.store.book().now[id]!.rec
        let taps = (rec["done_ats"]?.arrayValue ?? []).compactMap { $0.objectValue }
        XCTAssertEqual(taps.count, 2, "every tap is kept, on one day too")
        XCTAssertEqual(taps[0]["item"]?.stringValue, "organizer.tasks/" + String(id.prefix(8)))
        XCTAssertEqual(taps[0]["unseen"]?.boolValue, true, "an answer that did not see the latest is kept, and says so")
        XCTAssertLessThan(taps[0]["moment"].flatMap { if case .number(let n) = $0 { return n } else { return nil } } ?? 0,
                          taps[1]["moment"].flatMap { if case .number(let n) = $0 { return n } else { return nil } } ?? 0)
        let blob = String(data: try JSONEncoder().encode(taps), encoding: .utf8) ?? ""
        XCTAssertFalse(blob.contains("secret") || blob.contains("Chen"), "the tap record holds the pointer, never the title")
    }

    /// Not run when written. A moment is taken in the same step as the record write: a Done that fails takes none, so the next one is not
    /// numbered past a gap, and moments in a person's sequence run 1, 2, 3 across different tasks.
    @MainActor
    func testMomentsAreTakenWithTheWriteAndLeaveNoGap() async throws {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: CannedQuickAddReader(), clock: { Date() })
        try add(phone, "First")
        try add(phone, "Second")
        let ids = Array(try phone.store.book().now.keys)
        try await phone.send("complete", ["id": .string(ids[0]), "presented": Presentation.presented(Presentation.nextCard, pointer: "done")])
        do { try await phone.send("complete", ["id": .string("no-such-item")]); XCTFail("an unknown item is refused") } catch {}
        try await phone.send("skip", ["id": .string(ids[1]), "presented": Presentation.presented(Presentation.nextCard, pointer: "skip")])
        let book = try phone.store.book()
        func moment(_ id: String, _ key: String) -> Int? {
            if case .number(let n)? = book.now[id]?.rec[key]?.arrayValue?.first?.objectValue?["moment"] { return Int(n) } else { return nil }
        }
        XCTAssertEqual(moment(ids[0], "done_ats"), 1)
        XCTAssertEqual(moment(ids[1], "skipped_ats"), 2, "no gap, and one sequence for her across tasks and across Done and Skip")
    }
}
