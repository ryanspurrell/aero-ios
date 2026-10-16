import XCTest
@testable import Aero

/// The quick add result at the box, moving between days, and the tabs. The quick add words are canned (so the date is known); the day is
/// arranged by the real embedded reader, so these run in the simulator like EmbeddedReaderTests.
final class CannedQuickAddReader: ReaderRunning {
    var line: JSONValue = .null
    var failQuickAdd = false
    func call(_ name: String, _ args: [String: JSONValue]) async throws -> JSONValue {
        if name == "quickadd" {
            if failQuickAdd { throw ReaderFailure.said("forced for the test") }
            return line
        }
        return try await EmbeddedReader.shared.call(name, args)
    }
}

@MainActor
final class PhoneDaysTests: XCTestCase {
    func iso(_ daysFromToday: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: daysFromToday, to: Date())!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    func reading(_ title: String, due: String?) -> JSONValue {
        var first: [String: JSONValue] = ["type": .string("task"), "title": .string(title), "status": .string("open"), "attention": .string("inbox")]
        if let due { first["due"] = .string(due) }
        return .object(["first": .object(first), "more": .array([])])
    }

    func make(_ reader: CannedQuickAddReader) throws -> (PhoneOrganizer, QuickAddModel, OrganizerDayStore) {
        let phone = PhoneOrganizer(store: try PhoneStore(), reader: reader)
        return (phone, QuickAddModel(backend: phone), OrganizerDayStore(backend: phone))
    }

    func titles(_ store: OrganizerDayStore) -> [String] {
        ((store.answer?.day?.rows ?? []) + (store.answer?.day?.anytime ?? [])).compactMap(\.title)
    }

    // MARK: the words

    func testTheSavedWordsSayWhatAndWhen() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
        XCTAssertEqual(SavedWords.saved(title: "call mom", when: "2026-10-17", now: now, calendar: cal), "Saved for tomorrow: call mom")
        XCTAssertEqual(SavedWords.saved(title: "pack the bag", when: "2026-10-17 07:30", now: now, calendar: cal), "Saved for tomorrow at 7:30 am: pack the bag")
        XCTAssertEqual(SavedWords.saved(title: "water the plants", when: "2026-10-16 21:00", now: now, calendar: cal), "Saved for today at 9:00 pm: water the plants")
        XCTAssertEqual(SavedWords.saved(title: "dentist", when: "2026-10-20", now: now, calendar: cal), "Saved for Tuesday: dentist")
        XCTAssertEqual(SavedWords.saved(title: "renew pass", when: "2026-11-28", now: now, calendar: cal), "Saved for 28 Nov: renew pass")
        XCTAssertEqual(SavedWords.saved(title: "buy milk", when: nil, now: now, calendar: cal), "Saved without a day: buy milk")
    }

    // MARK: quick add for tomorrow

    func testAnItemForTomorrowIsConfirmedAndAppearsWhenMovingToTomorrow() async throws {
        let reader = CannedQuickAddReader()
        reader.line = reading("call mom", due: iso(1))
        let (_, model, store) = try make(reader)
        await store.load()
        XCTAssertFalse(titles(store).contains("call mom"), "not on today")
        await model.submit("call mom tomorrow")
        XCTAssertEqual(model.saved?.words, "Saved for tomorrow: call mom")
        XCTAssertEqual(model.saved?.day, iso(1))
        XCTAssertEqual(model.saved?.refs.count, 1)
        XCTAssertNil(model.stopped)
        await store.load()
        XCTAssertFalse(titles(store).contains("call mom"), "still not on today")
        await store.move(date: store.answer?.day?.next ?? iso(1))
        XCTAssertEqual(store.answer?.date, iso(1))
        XCTAssertTrue(titles(store).contains("call mom"), "an item with a date and no hour appears on its day, under 'No set time': \(titles(store))")
    }

    func testUndoTakesItBackAndTheDayNoLongerShowsIt() async throws {
        let reader = CannedQuickAddReader()
        reader.line = reading("call mom", due: iso(1))
        let (phone, model, store) = try make(reader)
        await model.submit("call mom tomorrow")
        await model.undo()
        XCTAssertEqual(model.saved?.words, "Taken back: call mom")
        XCTAssertTrue(model.saved?.refs.isEmpty ?? false)
        XCTAssertEqual(try phone.store.book().now.values.first?.status, "dropped")
        XCTAssertEqual(try phone.store.book().versions.values.first?.count, 2, "the change is a second version; nothing is erased")
        await store.move(date: iso(1))
        XCTAssertFalse(titles(store).contains("call mom"))
    }

    func testALineWithNoDaySaysSoAndIsOnTheListsTab() async throws {
        let reader = CannedQuickAddReader()
        reader.line = reading("buy milk", due: nil)
        let (_, model, store) = try make(reader)
        await model.submit("buy milk")
        XCTAssertEqual(model.saved?.words, "Saved without a day: buy milk")
        await store.select(.lists)
        XCTAssertEqual(store.lists?.flatMap(\.items).map(\.title), ["buy milk"])
    }

    // MARK: something stopped

    func testAReaderFailureSaysWhatWasBeingDoneWhichStepStoppedAndWhatToDo() async throws {
        let reader = CannedQuickAddReader()
        reader.failQuickAdd = true
        let (phone, model, _) = try make(reader)
        await model.submit("call mom tomorrow")
        XCTAssertNil(model.saved)
        let stopped = try XCTUnwrap(model.stopped)
        XCTAssertEqual(stopped.text, "Saving \u{201C}call mom tomorrow\u{201D} stopped at reading it. Your words are kept here.")
        XCTAssertEqual(stopped.key, "Try again")
        XCTAssertTrue(try phone.store.book().now.isEmpty, "nothing was half-saved")
        // the key does what it says: with the reader back, the same words are saved
        reader.failQuickAdd = false
        reader.line = reading("call mom", due: iso(1))
        await model.retry()
        XCTAssertNil(model.stopped)
        XCTAssertEqual(model.saved?.words, "Saved for tomorrow: call mom")
    }

    // MARK: the tabs

    func testTheTabsSwitchViewsAroundOneHeldDate() async throws {
        let reader = CannedQuickAddReader()
        reader.line = reading("call mom", due: iso(1))
        let (_, model, store) = try make(reader)
        await model.submit("call mom tomorrow")
        XCTAssertEqual(DayTab.allCases.map(\.title), ["Day", "Week", "Month", "Year", "Lists"])
        await store.move(date: iso(1))
        for tab in [DayTab.week, .month, .year] {
            await store.select(tab)
            XCTAssertEqual(store.tab, tab)
            XCTAssertEqual(store.answer?.span, tab.span)
            XCTAssertFalse(store.showLists)
        }
        await store.select(.lists)
        XCTAssertEqual(store.tab, .lists)
        XCTAssertTrue(store.showLists)
        XCTAssertEqual(store.lists?.first?.items.first?.title, "call mom")
        XCTAssertEqual(store.lists?.first?.items.first?.when, "tomorrow")
        await store.select(.day)
        XCTAssertEqual(store.tab, .day)
        XCTAssertEqual(store.answer?.date, iso(1), "the held date waited behind the other tabs")
        XCTAssertTrue(titles(store).contains("call mom"))
    }
}
