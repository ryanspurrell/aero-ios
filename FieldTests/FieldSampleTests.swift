import XCTest
@testable import Field

/// Each test replays a theorem or example of FieldSample.lean as concrete cases. The theorem's name is in the test's name or its comment.
final class FieldSampleTests: XCTestCase {
    let m = Method.method7400

    func sample(id: Int = 1, start: Int = 0, stop: Int? = 200, before: Rat = 2, after: Rat? = 2, height: Int? = nil) -> Sample {
        Sample(id: id, pump: id, place: "example place", start: start, stop: stop, before: before, after: after, height: height)
    }

    // MARK: exact numbers

    func testRatParsesAndPrintsDecimalsExactly() {
        XCTAssertEqual(Rat.parse("2.5"), Rat(5, 2))
        XCTAssertEqual(Rat.parse("0,45"), Rat(9, 20))
        XCTAssertEqual(Rat.parse("0.1")! + Rat.parse("0.2")!, Rat.parse("0.3")!, "0.1 + 0.2 is exactly 0.3, unlike Double")
        XCTAssertNil(Rat.parse("abc")); XCTAssertNil(Rat.parse("")); XCTAssertNil(Rat.parse("-1")); XCTAssertNil(Rat.parse("1.2.3"))
        XCTAssertEqual(Rat(5, 2).text(), "2.5")
        XCTAssertEqual(Rat(400).text(), "400")
        XCTAssertEqual(Rat(1, 3).text(), "about 0.33")
    }

    func testDivisionByZeroIsZeroAsInLean() {
        XCTAssertEqual(Rat(5) / Rat(0), Rat(0))
        XCTAssertEqual(dueRun(400, 0), 0)
    }

    // MARK: Part B: volume

    func testVolumeZeroTime() { XCTAssertEqual(volume(3, 5, 0), 0) }          // volume_zero_time

    func testVolumeMonotone() {                                                // volume_mono_time, _before, _after
        XCTAssertTrue(volume(2, 2, 10) <= volume(2, 2, 11))
        XCTAssertTrue(volume(2, 2, 10) <= volume(3, 2, 10))
        XCTAssertTrue(volume(2, 2, 10) <= volume(2, 3, 10))
    }

    func testVolumeIsMeanOfFlowsTimesMinutes() { XCTAssertEqual(volume(2, 3, 100), 250) }

    // MARK: Part C: the state

    func testExamplesOfTheLeanFile() {
        XCTAssertEqual(state(m, sample()), .counts)                                                         // exCounts: 2 L/min, 200 min = 400 L
        XCTAssertEqual(state(m, sample(stop: 100)), .fails(.volumeShort))                                   // exShort
        XCTAssertEqual(state(m, sample(stop: nil, after: nil)), .notYet(.running))
        XCTAssertEqual(dueRun(400, 10), 40)
    }

    func testRunningSampleNeverCounts() {                                       // running_not_yes, state_running
        for after in [nil, Rat(2)] {
            let s = sample(stop: nil, after: after)
            XCTAssertEqual(state(m, s), .notYet(.running))
            XCTAssertNotEqual(toFour(state(m, s)), .yes)
        }
    }

    func testStoppedWithoutAfterFlowNeverCounts() {                             // afterMissing_not_yes, state_afterMissing
        let s = sample(after: nil)
        XCTAssertEqual(state(m, s), .notYet(.afterMissing))
        XCTAssertNotEqual(toFour(state(m, s)), .yes)
    }

    func testFailedCheckNamesItsReason() {                                      // failed_not_yes, no_names_a_failed_check
        let cases: [(Sample, Check)] = [
            (sample(start: 50, stop: 10), .timesOrder),
            (sample(before: Rat(1, 4)), .beforeOutOfBand),
            (sample(before: 17), .beforeOutOfBand),
            (sample(after: 20), .afterOutOfBand),
            (sample(stop: 100, after: Rat(1, 4)), .afterOutOfBand),
            (sample(after: Rat(23, 10)), .drift),
            (sample(stop: 100), .volumeShort),
        ]
        for (s, c) in cases {
            XCTAssertEqual(state(m, s), .fails(c), "\(c)")
            XCTAssertEqual(toFour(state(m, s)), .no)
            XCTAssertTrue(failedB(m, s, s.stop!, s.after!, c), "the named check really failed")
            XCTAssertNotEqual(toFour(state(m, s)), .yes)
        }
    }

    func testFirstFailingCheckInOrderIsTheOneNamed() {                          // verdict: Check.all.find?
        // stop before start AND flow out of band: timesOrder comes first
        XCTAssertEqual(state(m, sample(start: 50, stop: 10, before: 20)), .fails(.timesOrder))
        // before out of band AND volume short: beforeOutOfBand comes first
        XCTAssertEqual(state(m, sample(stop: 10, before: 20)), .fails(.beforeOutOfBand))
        XCTAssertEqual(Check.all, [.timesOrder, .beforeOutOfBand, .afterOutOfBand, .drift, .volumeShort])
    }

    func testCountsExactlyWhenNoCheckFails() {                                  // state_counts_iff, verdict_counts_iff
        for stop in [10, 100, 199, 200, 300] {
            for after in [Rat(2), Rat(21, 10), Rat(5, 2), Rat(1, 10)] {
                let s = sample(stop: stop, after: after)
                let noneFail = Check.all.allSatisfy { !failedB(m, s, stop, after, $0) }
                XCTAssertEqual(state(m, s) == .counts, noneFail)
            }
        }
    }

    func testBoundaryOfTheDriftAndVolumeChecks() {
        XCTAssertEqual(state(m, sample(stop: 200, after: Rat(21, 10))), .counts, "a difference of exactly 0.1 is allowed (tol < diff fails, not <=)")
        XCTAssertEqual(state(m, sample(stop: 200, after: 2)), .counts, "exactly 400 L counts")
        XCTAssertEqual(state(m, sample(stop: 199, after: 2)), .fails(.volumeShort))
    }

    func testFourMapping() {                                                    // toFour_ne_all, toFour_no_iff, toFour_none_iff
        XCTAssertEqual(toFour(.counts), .yes)
        XCTAssertEqual(toFour(.fails(.drift)), .no)
        XCTAssertEqual(toFour(.notYet(.running)), .none)
        XCTAssertEqual(toFour(.notYet(.afterMissing)), .none)
        for st in [SampleState.counts, .fails(.drift), .notYet(.running)] { XCTAssertNotEqual(toFour(st), .all) }
    }

    func testCombineIsAllOnlyWhereTwoReadingsDisagree() {                       // combine_self, combine_eq_all_iff
        XCTAssertEqual(combine(.counts, .counts), .yes)
        XCTAssertEqual(combine(.counts, .fails(.drift)), .all)
        XCTAssertEqual(combine(.fails(.drift), .fails(.drift)), .no)
        XCTAssertEqual(combine(.fails(.drift), .fails(.timesOrder)), .all)
    }

    // MARK: Part D: several pumps

    func testAddingAPumpLeavesOthersUnchanged() {                               // add_independent, add_keeps_distinct
        let r: Run = [sample(id: 1), sample(id: 2, stop: nil, after: nil), sample(id: 3, after: nil)]
        let n = sample(id: freshId(r), stop: 50)
        let r2 = adding(r, n)!
        XCTAssertTrue(isDistinct(r2))
        for j in [1, 2, 3] { XCTAssertEqual(stateOf(m, r2, j), stateOf(m, r, j)) }
        XCTAssertEqual(stateOf(m, r2, n.id), .fails(.volumeShort))
        XCTAssertNil(adding(r, sample(id: 2)), "an id already there is refused")
    }

    func testEditingOnePumpLeavesOthersUnchanged() {                            // stop_independent, setAfter_independent, edit_independent, *_keeps_distinct
        let r: Run = [sample(id: 1, stop: nil, after: nil), sample(id: 2, stop: nil, after: nil), sample(id: 3, stop: 100)]
        let stopped = stopAt(r, 1, 200)
        XCTAssertEqual(stateOf(m, stopped, 1), .notYet(.afterMissing))
        for j in [2, 3] { XCTAssertEqual(stateOf(m, stopped, j), stateOf(m, r, j)) }
        XCTAssertTrue(isDistinct(stopped))
        let flowed = setAfter(stopped, 1, 2)
        XCTAssertEqual(stateOf(m, flowed, 1), .counts)
        for j in [2, 3] { XCTAssertEqual(stateOf(m, flowed, j), stateOf(m, r, j)) }
        XCTAssertTrue(isDistinct(flowed))
        XCTAssertEqual(flowed.map(\.id), r.map(\.id), "edit_ids: the ids are the same, in the same order")
    }

    func testEditCannotChangeAnId() {                                           // the hypothesis `hf` of edit_independent
        let r: Run = [sample(id: 1), sample(id: 2)]
        let e = edit(r, 1) { var s = $0; s.id = 2; s.place = "moved"; return s }
        XCTAssertEqual(e.map(\.id), [1, 2])
        XCTAssertEqual(e[0].place, "moved")
    }

    func testFreshIdIsNew() {
        XCTAssertEqual(freshId([]), 1)
        XCTAssertEqual(freshId([sample(id: 4), sample(id: 9)]), 10)
    }

    // MARK: Part E: the timer

    func testStopDueMeetsTheMinimumAndOneMinuteEarlierDoesNot() {               // stopDue_meets_minimum, before_stopDue_short, stopDue_run
        for flow in [Rat(2), Rat(10), Rat(3), Rat(7, 2), Rat(1, 2), Rat(16), Rat(13, 10)] {
            let due = stopDue(1000, 400, flow)
            XCTAssertTrue(400 <= volume(flow, flow, due - 1000), "flow \(flow.text())")
            XCTAssertEqual(due - 1000, dueRun(400, flow))
            if dueRun(400, flow) > 0 {
                XCTAssertTrue(volume(flow, flow, dueRun(400, flow) - 1) < 400, "flow \(flow.text())")
            }
        }
        XCTAssertEqual(dueRun(400, 3), 134)   // 133.33 minutes rounds up to the first whole minute that gets there
    }

    // MARK: Part G: the method's numbers

    func testMethod7400NumbersAreTheLeanFiles() {
        XCTAssertEqual(m.lo, Rat(1, 2)); XCTAssertEqual(m.hi, 16); XCTAssertEqual(m.tol, Rat(1, 10)); XCTAssertEqual(m.minVol, 400)
    }
}
