import XCTest
@testable import Aero

/// The record shape, read in Swift from the same invented fixture files the Python tests read (projects/organizer/test_record_shape.py),
/// with the same expected answers (expected.json): the current version of each record, the chain of a record, and the forks.
final class RecordShapeTests: XCTestCase {
    static func lines(_ name: String) throws -> [RecordVersion] {
        let url = try XCTUnwrap(Bundle(for: RecordShapeTests.self).url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures/record_shape"), "fixture \(name) is not in the test bundle")
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { try JSONDecoder().decode(RecordVersion.self, from: Data($0.utf8)) }
    }

    struct Expected: Decodable {
        struct Current: Decodable { var id: String; var title: String; var status: String }
        struct Head: Decodable { var id: String; var install: String; var at: String }
        var current: [String: Current]
        var chains: [String: [String]]
        var conflicts: [String: [Head]]
    }

    func expected() throws -> [String: Expected] {
        let url = try XCTUnwrap(Bundle(for: RecordShapeTests.self).url(forResource: "expected", withExtension: "json", subdirectory: "Fixtures/record_shape"))
        return try JSONDecoder().decode([String: Expected].self, from: Data(contentsOf: url))
    }

    func testEveryFixtureLineDecodes() throws {
        for name in ["versions", "fork"] {
            let got = try Self.lines(name)
            XCTAssertFalse(got.isEmpty)
            for v in got {
                XCTAssertEqual(v.id.count, 32)
                XCTAssertEqual(v.kind, "org")
                XCTAssertFalse(v.type.isEmpty)
            }
        }
    }

    func testVersionsWithNoInstallAreStillRead() throws {
        let got = try Self.lines("versions")
        XCTAssertTrue(got.contains { $0.install == nil }, "the fixtures hold versions made before `install` was kept")
        XCTAssertTrue(got.contains { $0.install != nil })
        XCTAssertFalse(OrganizerBook(got.filter { $0.install == nil }).now.isEmpty)
    }

    func testAFieldAddedLaterByAnotherInstallPassesThrough() throws {
        let v = try XCTUnwrap(try Self.lines("fork").first { $0.title == "Invented: newer install's field" })
        XCTAssertNotNil(v.rec["a_field_added_later"])
        let again = try JSONDecoder().decode(RecordVersion.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(again.rec["a_field_added_later"], v.rec["a_field_added_later"])
        XCTAssertEqual(again.install, v.install)
    }

    func testBookReadsTheFixturesAsPythonDoes() throws {
        for (name, want) in try expected() {
            let book = OrganizerBook(try Self.lines((name as NSString).deletingPathExtension))
            XCTAssertEqual(Set(book.now.keys), Set(want.current.keys), name)
            for (oid, cur) in want.current {
                let v = try XCTUnwrap(book.now[oid])
                XCTAssertEqual([v.id, v.title, v.status], [cur.id, cur.title, cur.status], name)
            }
            for (oid, chain) in want.chains { XCTAssertEqual(book.versions[oid]?.map(\.id), chain, name) }
            XCTAssertEqual(Set(book.conflicts.keys), Set(want.conflicts.keys), name)
            for (oid, heads) in want.conflicts {
                XCTAssertEqual(book.conflicts[oid]?.map { [$0.id, $0.install ?? "", $0.at] }, heads.map { [$0.id, $0.install, $0.at] }, name)
            }
        }
    }

    func testAForkIsKeptWithWhenAndWhereAndTheLaterStillReads() throws {
        let book = OrganizerBook(try Self.lines("fork"))
        let oid = String(repeating: "0", count: 30) + "0a"
        XCTAssertEqual(book.now[oid]?.title, "Invented: renew the library card (PC)")
        XCTAssertEqual(book.conflicts[oid]?.count, 2)
        XCTAssertEqual(book.conflicts[oid]?.map(\.title), ["Invented: renew the library card (phone)", "Invented: renew the library card (PC)"])
    }

    func testASingleChainReadsAsBefore() throws {
        let book = OrganizerBook(try Self.lines("fork"))
        let oid = String(repeating: "0", count: 30) + "14"
        XCTAssertNil(book.conflicts[oid])
        XCTAssertEqual(book.versions[oid]?.map(\.title), ["Invented: one chain", "Invented: one chain, edited"])
    }
}
