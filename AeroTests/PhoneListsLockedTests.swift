import XCTest
@testable import Aero

/// Nothing Locked is shown on the phone: not a Locked list, not an Open task that sits in a Locked list, not a Locked list's name
/// handed to quick add. The PC's rule (organizer_service.py `visible_now` / `is_locked`), in the one place `PhoneOrganizer.mayShow`.
/// Written for the simulator; not compiled on the PC it was written on.
final class PhoneListsLockedTests: XCTestCase {
    func version(_ oid: String, _ rec: [String: JSONValue]) -> RecordVersion {
        RecordVersion(id: oid + "-v1", at: "2026-10-20T09:00:00", kind: "org", oid: oid, rec: rec, by: "test", why: nil, replaces: nil, key: nil, install: "i")
    }

    func testAnOpenTaskInALockedListIsNotListedAndTheListIsNotNamed() {
        let book = OrganizerBook([
            version("open-list", ["type": .string("project"), "title": .string("Open list"), "status": .string("active"), "locked": .bool(false)]),
            version("locked-list", ["type": .string("project"), "title": .string("Locked list"), "status": .string("active"), "locked": .bool(true)]),
            version("t1", ["type": .string("task"), "title": .string("In open list"), "status": .string("open"), "locked": .bool(false), "project": .string("open-list")]),
            version("t2", ["type": .string("task"), "title": .string("In locked list"), "status": .string("open"), "locked": .bool(false), "project": .string("locked-list")]),
            version("t3", ["type": .string("buy"), "title": .string("Milk in locked list"), "status": .string("open"), "locked": .bool(false), "project": .string("locked-list")]),
        ])
        let titles = PhoneLists.groups(book: book).flatMap { [$0.title] + $0.items.map(\.title) }
        XCTAssertTrue(titles.contains("In open list"))
        XCTAssertFalse(titles.contains("In locked list"), "an Open task in a Locked list is not shown under 'Not in a list'")
        XCTAssertFalse(titles.contains("Milk in locked list"))
        XCTAssertFalse(titles.contains("Locked list"))
    }

    func testOnlyOpenListsAreHandedToQuickAdd() {
        let open = version("a", ["type": .string("project"), "title": .string("A"), "status": .string("active"), "locked": .bool(false)])
        let locked = version("b", ["type": .string("project"), "title": .string("B"), "status": .string("active"), "locked": .bool(true)])
        let unmarked = version("c", ["type": .string("project"), "title": .string("C"), "status": .string("active")])
        let book = OrganizerBook([open, locked, unmarked])
        XCTAssertTrue(PhoneOrganizer.mayShow(open, in: book))
        XCTAssertFalse(PhoneOrganizer.mayShow(locked, in: book))
        XCTAssertFalse(PhoneOrganizer.mayShow(unmarked, in: book), "unchecked is private")
    }
}
