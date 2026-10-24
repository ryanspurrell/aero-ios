import XCTest
@testable import Field

final class FieldStoreTests: XCTestCase {
    var t = 100_000
    func makeStore(_ p: FieldPersistence? = nil) -> FieldStore { FieldStore(persistence: p, clock: { self.t }) }

    func testStartsAsAPracticeCopy() {
        XCTAssertTrue(makeStore().practice)
    }

    func testAddingPumpsGivesDistinctIdsAndStartsNow() {
        let s = makeStore()
        let a = s.addPump(place: "Building 1, Room 101", pump: 1, before: 2)
        let b = s.addPump(place: "Building 1, Room 102", pump: 2, before: Rat.parse("2.5")!)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(isDistinct(s.data.run))
        XCTAssertEqual(s.data.run.first(where: { $0.id == a })?.start, 100_000)
    }

    func testStopNowAndAfterFlowGiveTheVerdict() {
        let s = makeStore()
        let a = s.addPump(place: "x", pump: 1, before: 2)
        let b = s.addPump(place: "y", pump: 2, before: 2)
        t += 200
        s.stop(a)
        XCTAssertEqual(s.state(of: s.data.run.first(where: { $0.id == a })!), .notYet(.afterMissing))
        s.setAfter(a, 2)
        XCTAssertEqual(s.state(of: s.data.run.first(where: { $0.id == a })!), .counts)
        XCTAssertEqual(s.state(of: s.data.run.first(where: { $0.id == b })!), .notYet(.running), "the other pump is unchanged")
    }

    func testRemovingAPumpLeavesTheOthersAsTheyWere() {
        let s = makeStore()
        let a = s.addPump(place: "x", pump: 1, before: 2)
        let b = s.addPump(place: "y", pump: 2, before: 3)
        let before = s.data.run.first(where: { $0.id == b })
        s.removePump(a)
        XCTAssertEqual(s.data.run.first(where: { $0.id == b }), before)
        XCTAssertEqual(s.data.run.count, 1)
    }

    func testHandoverThatBreaksTheChainIsRefusedAndNothingChanges() {
        let s = makeStore()
        let p1 = s.person(named: "Person 1"), p2 = s.person(named: "Person 2"), p3 = s.person(named: "Person 3")
        XCTAssertNil(s.addHandover(Handover(giver: p1, taker: p2, time: 10)))
        XCTAssertEqual(s.addHandover(Handover(giver: p1, taker: p3, time: 12)), .giverIsNotLastTaker(expected: p2))
        XCTAssertEqual(s.addHandover(Handover(giver: p2, taker: p3, time: 9)), .timeGoesBack(last: 10))
        XCTAssertEqual(s.data.handovers.count, 1)
        XCTAssertNil(s.addHandover(Handover(giver: p2, taker: p3, time: 11)))
        XCTAssertTrue(isValid(s.data.handovers))
    }

    func testSheetIsMadeFromTheCardsAndSaysWhatEachOneIs() {
        let s = makeStore()
        s.loadExample()
        let text = s.sheet()
        XCTAssertTrue(text.contains("practice copy"))
        XCTAssertTrue(text.contains("Counts"))
        XCTAssertTrue(text.contains("Doesn't count"))
        XCTAssertTrue(text.contains("Still running"))
        XCTAssertTrue(text.contains("Waiting for flow after"))
        XCTAssertTrue(text.contains("The chain is unbroken."))
        XCTAssertTrue(text.contains("Not sent anywhere"))
    }

    func testExampleCoversEveryKindOfState() {
        let s = makeStore()
        s.loadExample()
        let kinds = Set(s.data.run.map { toFour(s.state(of: $0)) })
        XCTAssertEqual(kinds, [.yes, .no, .none])
        XCTAssertTrue(isDistinct(s.data.run))
    }

    func testRecordsPersistOnTheDeviceAndEraseRemovesThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("field-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = makeStore(FieldPersistence(url: url))
        a.addPump(place: "Building 1", pump: 1, before: Rat.parse("2.5")!)
        a.keepTicket(kind: .edgeCase, screen: "Board", step: "after Stop", what: "it stopped twice")
        let b = makeStore(FieldPersistence(url: url))
        XCTAssertEqual(b.data, a.data)
        XCTAssertEqual(b.data.run.first?.before, Rat(5, 2), "an exact flow survives a save and a load")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        b.eraseEverything()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(b.data.run.isEmpty && b.data.tickets.isEmpty)
        XCTAssertTrue(b.practice, "an erased copy goes back to practice")
    }

    func testTicketsAreKeptForTheOwnerOnTheDeviceAndShowExactlyTheirLines() {
        let s = makeStore()
        s.setOwner("Owner of this install")
        let k = s.keepTicket(kind: .brokenPlace, screen: "Board", step: "", what: "the timer froze")
        XCTAssertEqual(s.data.tickets, [k])
        XCTAssertEqual(k.to, "Owner of this install")
        let lines = TicketText.lines(k)
        XCTAssertEqual(lines.first, "To: Owner of this install")
        XCTAssertTrue(lines.contains("Kind: A place that doesn't work"))
        XCTAssertTrue(lines.contains("Step: not said"))
        XCTAssertEqual(Set(TicketKind.allCases.map(FieldWording.kind)).count, 4)
        // a ticket holds the screen, step and shape of what happened; it has no field for pumps, places, flows, times or names
        let fields = Mirror(reflecting: k).children.compactMap(\.label)
        XCTAssertEqual(Set(fields), ["id", "kind", "screen", "step", "what", "to", "practice", "made"])
    }

    func testPracticeAnswersAreFourValuedAndKeptOnce() {
        let s = makeStore()
        s.answer(situation: "ladder-trip", .all, note: "partly")
        s.answer(situation: "ladder-trip", .yes, note: "yes")
        XCTAssertEqual(s.data.answers.count, 1)
        XCTAssertEqual(s.data.answers.first?.answer, .yes)
        XCTAssertEqual(Four.allCases.map(FieldWording.fourWords), ["Yes", "No", "Partly", "Can't tell"])
    }

    func testPlannedSampleBecomesARunningPump() {
        let s = makeStore()
        s.addPlanned(place: "Building 1, Attic", height: 310, flow: FieldStore.plannedFlow)
        let id = s.data.plan[0].id
        s.startPlanned(id)
        XCTAssertTrue(s.data.plan.isEmpty)
        XCTAssertEqual(s.data.run.first?.height, 310)
        XCTAssertEqual(s.data.run.first?.stop, nil)
    }

    func testWordsGiveTheReasonAndTheNumbers() {
        let m = Method.method7400
        let short = Sample(id: 1, pump: 1, place: "x", start: 0, stop: 100, before: 2, after: 2, height: nil)
        let w = FieldWording.words(m, short)
        XCTAssertEqual(w.headline, "Doesn't count")
        XCTAssertEqual(w.detail, "200 L collected. It needs 400 L.")
        XCTAssertEqual(w.four, .no)
        let drift = Sample(id: 2, pump: 2, place: "x", start: 0, stop: 200, before: 2, after: Rat(23, 10), height: nil)
        XCTAssertEqual(FieldWording.words(m, drift).detail, "Flow changed by 0.3 L/min. At most 0.1 is allowed.")
    }

    func testTimerClockText() {
        XCTAssertEqual(StopTimer.clock(4325), "1:12:05")
        XCTAssertEqual(StopTimer.clock(65), "1:05")
        XCTAssertEqual(StopTimer.clock(-3), "0:00")
        XCTAssertEqual(FieldClock.span(72), "1 h 12 min")
    }

    func testPDFIsMadeFromTheTextAlone() {
        let d = PDFSheet.data("Chain of custody\nSample 1")
        XCTAssertTrue(d.count > 100)
        XCTAssertEqual(String(data: d.prefix(4), encoding: .ascii), "%PDF")
    }
}
