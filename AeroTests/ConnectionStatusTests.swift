import XCTest
@testable import Aero

/// The connection mark against Systems/ConnectionStatus.lean (Fingus repository, branch native-fix-server): each test is the statement of the
/// theorem it names, tried on every combination, since there are only nine.
final class ConnectionStatusTests: XCTestCase {
    private let all = Saw.allCases

    func testStatusIsTheSameEitherWayRound() {          // status_comm
        for a in all { for b in all { XCTAssertEqual(ConnectionStatus.status(a, b), ConnectionStatus.status(b, a)) } }
    }

    func testAReaderThatHasSeenNothingChangesNothing() {          // status_nothingYet_left, status_nothingYet_right, phone_alone
        for a in all {
            XCTAssertEqual(ConnectionStatus.status(a, .nothingYet), a.reading)
            XCTAssertEqual(ConnectionStatus.status(.nothingYet, a), a.reading)
        }
    }

    func testTwoThatAgreeStay() {          // status_agree
        for a in all { XCTAssertEqual(ConnectionStatus.status(a, a), a.reading) }
    }

    func testAReachedAndARefusedTogetherReadAll() {          // status_disagree_all, status_all_iff
        for a in all {
            for b in all {
                let disagree = (a == .reached && b == .refused) || (a == .refused && b == .reached)
                XCTAssertEqual(ConnectionStatus.status(a, b) == .all, disagree)
            }
        }
    }

    func testNoneYesAndNoAreReadOnlyFromWhatWasSeen() {          // status_none_iff, status_yes_iff, status_no_iff
        for a in all {
            for b in all {
                let s = ConnectionStatus.status(a, b)
                XCTAssertEqual(s == .none, a == .nothingYet && b == .nothingYet)
                XCTAssertEqual(s == .yes, (a == .reached || b == .reached) && a != .refused && b != .refused)
                XCTAssertEqual(s == .no, (a == .refused || b == .refused) && a != .reached && b != .reached)
            }
        }
    }

    func testThePCIsUsedWithAnAddressAndThePhoneWithout() {          // backendOf_pc_iff, whyOffered_iff, whyOffered_phone_alone
        XCTAssertEqual(ConnectionStatus.backend(hasAddress: true), .pc)
        XCTAssertEqual(ConnectionStatus.backend(hasAddress: false), .phone)
        for h in [true, false] { XCTAssertEqual(ConnectionStatus.whyOffered(hasAddress: h), ConnectionStatus.backend(hasAddress: h) == .pc) }
        XCTAssertFalse(ConnectionStatus.whyOffered(hasAddress: false))
    }

    func testTheTwoPlacesAreToldApartByTheirWords() {          // label_ne
        XCTAssertEqual(ConnectionStatus.label(.phone), "This phone")
        XCTAssertEqual(ConnectionStatus.label(.pc), "Your PC")
    }

    func testTheTimeMovesOnlyWhenTheReadingDoes() {          // step_same_keeps, step_changed_moves, step_since_le, step_reading
        let t0 = Date(timeIntervalSince1970: 1000), t1 = Date(timeIntervalSince1970: 2000)
        let start = ConnectionStatus.Shown(reading: .yes, since: t0)
        XCTAssertEqual(ConnectionStatus.step(start, new: .yes, at: t1), start)
        let moved = ConnectionStatus.step(start, new: .no, at: t1)
        XCTAssertEqual(moved, ConnectionStatus.Shown(reading: .no, since: t1))
        for new in Four.allCases {
            let s = ConnectionStatus.step(start, new: new, at: t1)
            XCTAssertEqual(s.reading, new)
            XCTAssertLessThanOrEqual(s.since, t1)
        }
    }

    func testTheWordsSayThePlaceWhatWasSeenAndSinceWhen() {
        func shown(_ r: Four) -> ConnectionStatus.Shown { .init(reading: r, since: Date(timeIntervalSince1970: 0)) }
        let time: (Date) -> String = { _ in "5:41 am" }
        XCTAssertEqual(ConnectionStatus.words(backend: .pc, shown: shown(.yes), time: time), "Your PC · reached since 5:41 am")
        XCTAssertEqual(ConnectionStatus.words(backend: .pc, shown: shown(.no), time: time), "Your PC · not reached since 5:41 am")
        XCTAssertEqual(ConnectionStatus.words(backend: .pc, shown: shown(.none), time: time), "Your PC · no answer yet")
        XCTAssertEqual(ConnectionStatus.words(backend: .pc, shown: shown(.all), time: time), "Your PC · phone and PC disagree since 5:41 am")
        XCTAssertEqual(ConnectionStatus.words(backend: .phone, shown: shown(.yes), time: time), "This phone · reached since 5:41 am")
        // a reading is never told by colour alone: each has its own symbol
        XCTAssertEqual(Set(Four.allCases.map(ConnectionStatus.symbol)).count, 4)
    }

    @MainActor
    func testTheMonitorKeepsWhatThePhoneSawAndWhatThePCSaid() {
        var now = Date(timeIntervalSince1970: 1000)
        let m = ConnectionMonitor(clock: { now }, backend: .pc)
        XCTAssertEqual(m.shown.reading, .none)
        m.sawOwn(.reached, backend: .pc)
        XCTAssertEqual(m.shown, ConnectionStatus.Shown(reading: .yes, since: Date(timeIntervalSince1970: 1000)))
        now = Date(timeIntervalSince1970: 2000)
        m.sawOwn(.reached, backend: .pc)
        XCTAssertEqual(m.shown.since, Date(timeIntervalSince1970: 1000))          // the same reading again: the time stays
        now = Date(timeIntervalSince1970: 3000)
        m.sawOwn(.refused, backend: .pc)
        XCTAssertEqual(m.shown, ConnectionStatus.Shown(reading: .no, since: Date(timeIntervalSince1970: 3000)))
        // the PC says it answers while the phone was refused: they disagree
        now = Date(timeIntervalSince1970: 4000)
        m.pcSaid(.reached)
        XCTAssertEqual(m.shown, ConnectionStatus.Shown(reading: .all, since: Date(timeIntervalSince1970: 4000)))
        // the phone sees something different, so the PC's word about the earlier moment no longer counts
        now = Date(timeIntervalSince1970: 5000)
        m.sawOwn(.reached, backend: .pc)
        XCTAssertEqual(m.shown, ConnectionStatus.Shown(reading: .yes, since: Date(timeIntervalSince1970: 5000)))
    }

    @MainActor
    func testWithNoPCThePhonesOwnReadingStandsAloneAndAnotherPlaceStartsAgain() {
        let m = ConnectionMonitor(clock: { Date(timeIntervalSince1970: 10) }, backend: .phone)
        m.sawOwn(.reached, backend: .phone)
        XCTAssertEqual(m.shown.reading, .yes)
        m.pcSaid(.refused)          // there is no PC to say anything
        XCTAssertEqual(m.shown.reading, .yes)
        XCTAssertEqual(m.words, "This phone · reached since " + ConnectionStatus.shortTime(Date(timeIntervalSince1970: 10)))
        // a request to the PC is another place: nothing carries over from the phone
        m.sawOwn(.refused, backend: .pc)
        XCTAssertEqual(m.backend, .pc)
        XCTAssertEqual(m.shown.reading, .no)
    }
}
