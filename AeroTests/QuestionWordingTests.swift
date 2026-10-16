import XCTest
@testable import Aero

/// The question sheet's words are cut to what differs. The labels are the reader's own (copied from its answers to invented lines).
final class QuestionWordingTests: XCTestCase {
    func question(_ labels: [String], capture: String = "call Sam at 9", title: String? = "call Sam") -> Question {
        Question(id: "abcd1234", ask: "at 9: long words from the reader", capture: capture, title: title,
                 choices: labels.enumerated().map { QuestionChoice(index: $0.offset, label: $0.element, answer: Change(name: "update", args: [:])) })
    }

    func testAMorPMKeepsTheHourAndSaysTheDayOnlyWhenTheyDiffer() {
        let w = QuestionWords.make(question: question(["9:00 PM Today · Wednesday 14 October", "9:00 AM Tomorrow · Thursday 15 October"]))
        XCTAssertEqual(w.title, "Call Sam")
        XCTAssertEqual(w.typed, "call Sam at 9")
        XCTAssertEqual(w.ask, "9 in the morning or evening?")
        XCTAssertEqual(w.chips.map(\.text), ["9 PM today", "9 AM tomorrow"])
        let same = QuestionWords.make(question: question(["12:00 AM Tomorrow · Thursday 15 October", "12:00 PM Tomorrow · Thursday 15 October"]))
        XCTAssertEqual(same.chips.map(\.text), ["12 AM", "12 PM"])
    }

    func testTheTypedWordsAreShownOnlyWhenTheyDifferFromTheTitle() {
        XCTAssertNil(QuestionWords.make(question: question(["9:00 AM Today · Friday 16 October", "9:00 PM Today · Friday 16 October"], capture: "Call Sam", title: "call sam")).typed)
    }

    func testTheSameWeekdayOnTwoDatesSaysWhichWeekday() {
        let w = QuestionWords.make(question: question(["Friday 16 October", "Friday 23 October"], capture: "dentist next friday", title: "dentist"))
        XCTAssertEqual(w.ask, "Which Friday?")
        XCTAssertEqual(w.chips.map(\.text), ["Fri 16", "Fri 23"])
    }

    func testDatesAreShortenedAndWhatTheyShareIsDropped() {
        let w = QuestionWords.make(question: question(["Thursday 10 December", "Tuesday 12 October 2027"], capture: "party 10/12", title: "party"))
        XCTAssertEqual(w.ask, "Which date?")
        XCTAssertEqual(w.chips.map(\.text), ["Thu 10 Dec", "Tue 12 Oct 2027"])
    }
}
