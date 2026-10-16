import XCTest
@testable import Aero

final class PhoneStoreTests: XCTestCase {
    func hex32(_ s: String) -> Bool { s.count == 32 && s.allSatisfy { "0123456789abcdef".contains($0) } }

    func testIdsAreRandom128BitHex() {
        let ids = (0..<50).map { _ in PhoneStore.newID() }
        XCTAssertTrue(ids.allSatisfy(hex32))
        XCTAssertEqual(Set(ids).count, 50)
    }

    func testAtIsTheSameShapeAsThePCsAndSorts() {
        let a = PhoneStore.stamp(Date(timeIntervalSince1970: 1_800_000_000.25))
        XCTAssertNotNil(a.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{6}Z$"#, options: .regularExpression), a)
        XCTAssertLessThan(PhoneStore.stamp(Date(timeIntervalSince1970: 1_800_000_000)), PhoneStore.stamp(Date(timeIntervalSince1970: 1_800_000_001)))
    }

    func testAChangeIsANewVersionThatNamesTheOneItReplacesAndTheInstall() throws {
        let store = try PhoneStore()
        let first = try store.put(oid: "o1", rec: ["type": .string("task"), "title": .string("Invented: water the ferns"), "status": .string("open")], by: "person:owner", why: "added", replaces: nil)
        let second = try store.put(oid: "o1", rec: ["type": .string("task"), "title": .string("Invented: water the ferns"), "status": .string("done")], by: "person:owner", why: "done", replaces: first.id)
        XCTAssertTrue(hex32(first.id) && hex32(second.id) && hex32(store.installID))
        XCTAssertEqual(second.replaces, first.id)
        XCTAssertEqual([first.install, second.install], [store.installID, store.installID])
        let book = try store.book()
        XCTAssertEqual(book.now["o1"]?.status, "done")
        XCTAssertEqual(book.versions["o1"]?.map(\.id), [first.id, second.id])
        XCTAssertTrue(book.conflicts.isEmpty)
    }

    func testNothingIsOverwrittenAndUnknownFieldsSurvive() throws {
        let store = try PhoneStore()
        try store.put(oid: "o1", rec: ["type": .string("task"), "title": .string("x"), "a_field_added_later": .object(["n": .number(1)])], by: "p", why: "added", replaces: nil)
        let got = try store.versions()
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].rec["a_field_added_later"], .object(["n": .number(1)]))
    }

    func testTheInstallIdAndTheRecordsSurviveReopeningTheFile() throws {
        let path = NSTemporaryDirectory() + "phone-store-\(UUID().uuidString).sqlite"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let id: String
        do {
            let store = try PhoneStore(path: path)
            id = store.installID
            try store.put(oid: "o1", rec: ["type": .string("task"), "title": .string("kept")], by: "p", why: "added", replaces: nil)
        }
        let again = try PhoneStore(path: path)
        XCTAssertEqual(again.installID, id)
        XCTAssertEqual(try again.book().now["o1"]?.title, "kept")
        XCTAssertNotEqual(try PhoneStore().installID, id)
    }

    func testAVersionMadeElsewhereIsKeptAsItCameAndNotAddedTwice() throws {
        let store = try PhoneStore()
        let v = RecordVersion(id: String(repeating: "a", count: 32), at: "2026-10-12T11:30:00.000000Z", kind: "org", oid: "o9", rec: ["type": .string("task"), "title": .string("from a PC")],
                              by: "p", why: "added", replaces: nil, key: nil, install: String(repeating: "b", count: 32))
        try store.add(v); try store.add(v)
        XCTAssertEqual(try store.versions().count, 1)
        XCTAssertEqual(try store.versions()[0].install, String(repeating: "b", count: 32))
    }
}

/// A stand-in for the embedded reader: canned answers, and a record of what it was asked.
final class FakeReader: ReaderRunning {
    var asked: [String] = []
    var answers: [String: JSONValue] = [:]
    func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        asked.append(name)
        if name == "clean", answers[name] == nil { return args["fields"] ?? .null }       // the fields already in the forms a record keeps
        return answers[name] ?? .null
    }
}

final class FakeNotifications: NotificationScheduling {
    var pending: [String: DateComponents] = [:]
    var authorized = true
    var asks = 0
    func requestAuthorization() async -> Bool { asks += 1; return authorized }
    func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    func remove(_ identifiers: [String]) { for i in identifiers { pending[i] = nil } }
    func schedule(identifier: String, title: String, at: DateComponents) async throws { pending[identifier] = at }
}

final class PhoneOrganizerTests: XCTestCase {
    func make(_ reader: ReaderRunning) throws -> PhoneOrganizer {
        PhoneOrganizer(store: try PhoneStore(), reader: reader)
    }

    func testAQuestionTheLineLeftIsBuiltFromItsReadingsAndLikeliestIsSaidOnlyWhenLikelier() {
        let rec: [String: JSONValue] = [
            "title": .string("Invented: call Sam at 9"), "capture": .string("call Sam at 9"),
            "readings": .object(["state": .string("not answered"), "ask": .string("9 in the morning or the evening?"), "kept": .array([
                .object(["label": .string("9 AM"), "likelihood": .number(0.7), "items": .array([.object(["type": .string("task"), "args": .object(["due": .string("2026-10-15 09:00")])])])]),
                .object(["label": .string("9 PM"), "likelihood": .number(0.3), "items": .array([.object(["type": .string("task"), "args": .object(["due": .string("2026-10-14 21:00")])])])]),
            ])])]
        let q = PhoneOrganizer.question(oid: String(repeating: "c", count: 32), rec: rec)
        XCTAssertEqual(q?.choices.map(\.label), ["9 AM", "9 PM"])
        XCTAssertEqual(q?.choices[0].answer.name, "update")
        XCTAssertEqual(q?.choices[0].answer.args["id"], .string("cccccccc"))
        XCTAssertEqual(PhoneOrganizer.likeliest(rec), 0)
        var equal = rec
        var rd = rec["readings"]!.objectValue!
        rd["kept"] = .array(rd["kept"]!.arrayValue!.map { var o = $0.objectValue!; o["likelihood"] = .number(0.5); return .object(o) })
        equal["readings"] = .object(rd)
        XCTAssertNil(PhoneOrganizer.likeliest(equal), "equal shares: nothing is called likeliest")
        rd["state"] = .string("answered"); equal["readings"] = .object(rd)
        XCTAssertNil(PhoneOrganizer.question(oid: "x", rec: equal), "an answered question is not asked again")
    }

    func testACertainLineBecomesARecordMadeHereAndAskedNothing() async throws {
        let reader = FakeReader()
        reader.answers["quickadd"] = .object(["first": .object(["type": .string("task"), "title": .string("dentist"), "status": .string("open"), "attention": .string("inbox"), "due": .string("2026-10-16 14:00")]), "more": .array([])])
        let phone = try make(reader)
        let outcome = try await phone.quickAdd("dentist friday 2pm")
        XCTAssertNil(outcome.question)
        let book = try phone.store.book()
        XCTAssertEqual(book.now.count, 1)
        let v = try XCTUnwrap(book.now.values.first)
        XCTAssertEqual([v.title, v.install, v.by], ["dentist", phone.store.installID, PhoneOrganizer.person])
        XCTAssertEqual(v.rec["locked"], .bool(false))
        XCTAssertEqual(v.oid.count, 32)
    }

    func testAnUncertainLineKeepsItsReadingsAndAsks_AndAChoiceAnswersIt() async throws {
        let reader = FakeReader()
        let kept: JSONValue = .array([
            .object(["label": .string("9 AM"), "likelihood": .number(0.7), "items": .array([.object(["type": .string("task"), "args": .object(["due": .string("2026-10-15 09:00")])])])]),
            .object(["label": .string("9 PM"), "likelihood": .number(0.3), "items": .array([.object(["type": .string("task"), "args": .object(["due": .string("2026-10-14 21:00")])])])])])
        reader.answers["quickadd"] = .object(["first": .object(["type": .string("task"), "title": .string("call Sam at 9"), "status": .string("open"),
                                                                "readings": .object(["state": .string("not answered"), "kept": kept])]), "more": .array([])])
        let phone = try make(reader)
        let outcome = try await phone.quickAdd("call Sam at 9")
        let q = try XCTUnwrap(outcome.question)
        XCTAssertEqual(q.choices.count, 2)
        try await phone.apply(q.choices[1].answer)
        let book = try phone.store.book()
        let v = try XCTUnwrap(book.now.values.first)
        XCTAssertEqual(v.rec["due"], .string("2026-10-14 21:00"))
        XCTAssertEqual(v.rec["readings"]?.objectValue?["state"], .string("answered"))
        XCTAssertEqual(v.rec["readings"]?.objectValue?["picked"], .number(1))
        XCTAssertEqual(book.versions[v.oid]?.count, 2, "the change is a second version of the same record")
    }

    func testSomethingElseKeepsThePlainTaskInTheDay() async throws {
        let reader = FakeReader()
        reader.answers["quickadd"] = .object(["first": .object(["type": .string("task"), "title": .string("call Sam at 9"), "status": .string("open"),
            "readings": .object(["state": .string("not answered"), "kept": .array([.object(["label": .string("9 AM"), "likelihood": .number(0.5), "items": .array([.object(["type": .string("task"), "args": .object(["due": .string("2026-10-15 09:00")])])])])])])]), "more": .array([])])
        let phone = try make(reader)
        let outcome = try await phone.quickAdd("call Sam at 9")
        let q = try XCTUnwrap(outcome.question)
        try await phone.keepPlain(q)
        let v = try XCTUnwrap(try phone.store.book().now.values.first)
        XCTAssertEqual(v.rec["attention"], .string("now"))
        XCTAssertEqual(v.rec["readings"]?.objectValue?["state"], .string("declined"))
    }

    func testCompleteAndReopenAreNewVersions() async throws {
        let reader = FakeReader()
        let phone = try make(reader)
        let oid = PhoneStore.newID()
        try phone.store.put(oid: oid, rec: ["type": .string("task"), "title": .string("x"), "status": .string("open")], by: "p", why: "added", replaces: nil)
        try await phone.send("complete", ["id": .string(String(oid.prefix(8)))])
        XCTAssertEqual(try phone.store.book().now[oid]?.status, "done")
        XCTAssertNotNil(try phone.store.book().now[oid]?.rec["done_at"])
        try await phone.send("reopen", ["id": .string(String(oid.prefix(8)))])
        XCTAssertEqual(try phone.store.book().now[oid]?.status, "open")
        XCTAssertEqual(try phone.store.book().versions[oid]?.count, 3)
    }

    func testAThingNotOnThePhoneYetSaysSo() async throws {
        let phone = try make(FakeReader())
        do { try await phone.send("defer", [:]); XCTFail("expected a refusal") } catch { XCTAssertTrue(error.localizedDescription.contains("phone")) }
    }
}

final class PhoneRemindersTests: XCTestCase {
    func upcoming(_ n: Int) -> [PhoneReminders.Upcoming] {
        (0..<n).map { i in PhoneReminders.Upcoming(oid: String(format: "%032x", i), title: "Invented \(i)", fire: String(format: "2026-11-%02d 09:%02d", 1 + i / 60, i % 60)) }
    }

    func testOnlyTheNearest64AreScheduled() async {
        let center = FakeNotifications()
        await PhoneReminders(center: center).replace(with: upcoming(100))
        XCTAssertEqual(center.pending.count, 64)
        XCTAssertEqual(PhoneReminders.maxPending, 64)
        XCTAssertTrue(center.pending.keys.allSatisfy { $0.hasPrefix(PhoneReminders.prefix) })
    }

    func testTopUpAddsWhatIsMissingAndRemovesWhatIsNotWantedAndLeavesOthersAlone() async {
        let center = FakeNotifications()
        center.pending["someone.else"] = DateComponents(year: 2030)
        let r = PhoneReminders(center: center)
        let all = upcoming(70)
        await r.replace(with: Array(all.prefix(64)))
        // the first ones have fired; the next window opens
        await r.replace(with: Array(all.dropFirst(6)))
        XCTAssertEqual(center.pending.filter { $0.key.hasPrefix(PhoneReminders.prefix) }.count, 64)
        XCTAssertNil(center.pending[PhoneReminders.identifier(all[0])])
        XCTAssertNotNil(center.pending[PhoneReminders.identifier(all[69])])
        XCTAssertNotNil(center.pending["someone.else"])
    }

    func testPermissionIsAskedOnceAndOnlyWhenThereIsSomethingToTell() async {
        let center = FakeNotifications()
        let r = PhoneReminders(center: center)
        await r.replace(with: [])
        XCTAssertEqual(center.asks, 0)
        await r.replace(with: upcoming(2)); await r.replace(with: upcoming(3))
        XCTAssertEqual(center.asks, 1)
        let refused = FakeNotifications(); refused.authorized = false
        await PhoneReminders(center: refused).replace(with: upcoming(2))
        XCTAssertTrue(refused.pending.isEmpty)
    }

    func testTheFireTimeBecomesCalendarFields() {
        XCTAssertEqual(PhoneReminders.components("2026-11-03 14:05"), DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5))
        XCTAssertNil(PhoneReminders.components("soon"))
    }
}

/// The real thing: Python in the app, reading words and arranging a day. Runs in the simulator only (the build runs it there).
final class EmbeddedReaderTests: XCTestCase {
    func testAQuickAddLineBecomesARecordAndTheDayShowsIt() async throws {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: EmbeddedReader.shared)
        let outcome = try await phone.quickAdd("water the plants tonight at 9")
        XCTAssertNil(outcome.question)
        let day = try await phone.calendar(span: .day, date: "")
        let titles = (day.day?.rows ?? []).compactMap(\.title) + (day.day?.anytime ?? []).compactMap(\.title)
        XCTAssertTrue(titles.contains("water the plants"), "\(titles)")
        for span in [CalendarSpan.week, .month, .year] {
            let a = try await phone.calendar(span: span, date: "")
            XCTAssertEqual(a.span, span)
        }
    }

    func testAnUncertainLineAsksWithOnlyLiveReadings() async throws {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: EmbeddedReader.shared)
        let outcome = try await phone.quickAdd("call Sam at 9")
        let q = try XCTUnwrap(outcome.question)
        XCTAssertGreaterThanOrEqual(q.choices.count, 1)
        let day = try await phone.calendar(span: .day, date: "")
        XCTAssertNotNil(((day.day?.rows ?? []) + (day.day?.anytime ?? [])).compactMap(\.question).first, "the question waits in the day too")
    }
}
