import XCTest
@testable import Field

final class FieldCustodyTests: XCTestCase {
    func h(_ g: Int, _ t: Int, _ time: Int) -> Handover { Handover(giver: g, taker: t, time: time) }

    func testValidChainHasSortedTimes() {                                       // valid_times_sorted
        let c = [h(1, 2, 10), h(2, 3, 10), h(3, 4, 25)]
        XCTAssertTrue(isValid(c))
        XCTAssertTrue(timesSorted(c))
        XCTAssertEqual(c.map(\.time), c.map(\.time).sorted())
    }

    func testChainBreaksWhenTheGiverIsNotTheLastTakerOrTimeGoesBack() {         // Link
        XCTAssertFalse(isValid([h(1, 2, 10), h(3, 4, 20)]))
        XCTAssertFalse(isValid([h(1, 2, 10), h(2, 3, 5)]))
        XCTAssertTrue(isValid([])); XCTAssertTrue(isValid([h(1, 2, 10)]))
    }

    func testAppendingAKeptLinkKeepsTheChainValid() {                           // valid_append
        let c = [h(1, 2, 10)]
        XCTAssertEqual(appending(c, h(2, 3, 12)), [h(1, 2, 10), h(2, 3, 12)])
        XCTAssertTrue(isValid(appending(c, h(2, 3, 12))!))
        XCTAssertNil(appending(c, h(9, 3, 12)))
        XCTAssertNil(appending(c, h(2, 3, 9)))
        XCTAssertEqual(appending([], h(5, 6, 1)), [h(5, 6, 1)])
    }

    func testTheProblemIsNamed() {
        XCTAssertEqual(linkProblem(after: h(1, 2, 10), h(9, 3, 12)), .giverIsNotLastTaker(expected: 2))
        XCTAssertEqual(linkProblem(after: h(1, 2, 10), h(2, 3, 9)), .timeGoesBack(last: 10))
        XCTAssertNil(linkProblem(after: h(1, 2, 10), h(2, 3, 10)))
    }
}

final class FieldReachTests: XCTestCase {
    let high = Sample(id: 4, pump: 1, place: "example place", start: 0, stop: nil, before: 2, after: nil, height: 300)   // exHigh

    func testLeanExamples() {
        XCTAssertEqual(sampleReach([nil], high), .none)                 // a ladder said to exist, no height
        XCTAssertEqual(sampleReach([200], high), .no)
        XCTAssertEqual(sampleReach([200, 350], high), .yes)
        XCTAssertEqual(sampleReach([], high), .none)
        XCTAssertEqual(tripReady([200], [high]), .cannotReach(4))
        XCTAssertEqual(tripReady([nil], [high]), .unknown)
    }

    func testUnknownLadderHeightIsNotReady() {                           // unconfirmed_reach_not_ready
        XCTAssertNotEqual(tripReady([nil], [high]), .ready)
        XCTAssertNotEqual(tripReady([], [high]), .ready)
        XCTAssertNotEqual(tripReady([nil, nil], [high]), .ready)
    }

    func testUnknownSampleHeightIsNotReady() {                           // unknown_height_not_ready
        var s = high; s.height = nil
        XCTAssertNotEqual(tripReady([500], [s]), .ready)
        XCTAssertNotEqual(tripReady([500], [high, s]), .ready)
        XCTAssertEqual(tripReady([500], [high, s]), .unknown)
    }

    func testReadyMeansEverySampleHasAHeightAndAMeasuredToolThatReachesIt() {   // ready_iff, ready_reachable
        var low = high; low.id = 5; low.height = 90
        XCTAssertEqual(tripReady([350], [high, low]), .ready)
        XCTAssertEqual(tripReady([nil, 350], [high, low]), .ready, "an unmeasured tool does not stop a measured one from reaching")
        XCTAssertEqual(tripReady([100], [high, low]), .cannotReach(4))
    }

    func testANoNamesASampleThatReallyCannotBeReached() {                // cannotReach_names
        var low = high; low.id = 5; low.height = 90
        guard case .cannotReach(let id) = tripReady([100], [low, high]) else { return XCTFail() }
        XCTAssertEqual(sampleReach([100], [low, high].first(where: { $0.id == id })!), .no)
    }

    func testAShortfallCountsEvenWhenOtherThingsAreUnknown() {           // tripReady: the first "no" wins
        var unknown = high; unknown.id = 6; unknown.height = nil
        XCTAssertEqual(tripReady([200], [unknown, high]), .cannotReach(4))
    }

    func testReadyAndNeededAreMonotoneWhenASampleIsAdded() {             // ready_mono, needed_mono, needed_ge_height
        var low = high; low.id = 5; low.height = 90
        XCTAssertEqual(tripReady([350], [high, low]), .ready)
        XCTAssertEqual(tripReady([350], [low]), .ready)
        XCTAssertTrue(needed([low]) <= needed([high, low]))
        XCTAssertEqual(needed([]), 0)
        XCTAssertTrue(300 <= needed([high, low]))
    }

    func testTheLadderTripExampleEndsInTheRightAnswers() {
        let plan = Situations.ladderTrip.plan
        let s = Situations.ladderTrip.scenarios.map { $0.tools.map(\.reach) }
        XCTAssertEqual(tripReady(s[0], plan), .unknown)           // "they have one": the app has to ask how tall it is
        XCTAssertEqual(tripReady(s[1], plan), .cannotReach(2))    // 200 cm: the first sample it cannot reach is the vent at 240 (the attic at 310 too); known before leaving
        XCTAssertEqual(tripReady(s[2], plan), .ready)             // bring a 350 cm one
        XCTAssertEqual(needed(plan), 310)
    }
}
