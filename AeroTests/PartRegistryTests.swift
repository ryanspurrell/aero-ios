import XCTest
@testable import Aero

/// The part registry. The first group carries the names of the Lean theorems in ScreenWalk.lean (W-E, `Systems/ScreenWalk.lean` in the Fingus
/// repository); these are Swift checks on invented graphs, not the proofs. All data here is invented.
final class PartRegistryTests: XCTestCase {
    /// Home holds a, b; a holds a1 (which holds a2); b holds b1.
    private func graph() -> Holarchy {
        Holarchy.home(tiles: ["a", "b"], inside: { n in ["a": ["a1"], "a1": ["a2"], "b": ["b1"]][n] ?? [] })
    }
    private let walks: [[String]] = [[], ["a"], ["b"], ["a", "a1"], ["a", "a1", "a2"], ["b", "b1"]]

    func testAddTile_keeps_walks() {
        let g = graph(), added = g.addTile("c")
        for w in walks { XCTAssertTrue(g.ok(w)); XCTAssertTrue(added.ok(w), "\(w)") }
    }

    func testRemoveTile_keeps_walks() {
        let g = graph(), gone = g.removeTile("b")
        for w in walks where !w.contains("b") { XCTAssertTrue(gone.ok(w), "\(w)") }
        XCTAssertFalse(gone.ok(["b"]))
    }

    func testAddTile_reachable() {
        XCTAssertTrue(graph().addTile("c").ok(["c"]))
        XCTAssertTrue(Holarchy.home(tiles: []).addTile("c").ok(["c"]))
    }

    func testOpenRecent_gone() {
        let g = graph().removeTile("b")
        XCTAssertEqual(g.openRecent(from: ["a"], recent: ["b", "b1"]), ["a"])     // the recent place was removed: nothing moves
        XCTAssertEqual(g.openRecent(from: [], recent: ["a", "a1"]), ["a", "a1"])  // one that is still a place opens
    }

    func testOtherTilesKeepTheirOrderWhenOneIsAddedOrRemoved() {
        let before = ["organizer", "messages", "photos"]
        let added = PartsSelection.adding(before, "money")
        XCTAssertEqual(Array(added.prefix(3)), before)
        XCTAssertEqual(PartsSelection.removing(added, "messages"), ["organizer", "photos", "money"])
        XCTAssertEqual(PartsSelection.adding(before, "messages"), before)         // already there: stays where it is
    }

    func testTilesFollowTheAddedOrderAndKeepUnofferedPartsInPlace() {
        let parts = PartCatalog.merged(core: nil)
        XCTAssertEqual(PartsSelection.tiles(added: ["messages", "organizer"], parts: parts, hasPC: true).map(\.id), ["messages", "organizer"])
        // no PC: Chats are not offered (never offered and then failing), Organizer is; and an id this build has never heard of is not drawn
        XCTAssertEqual(PartsSelection.tiles(added: ["messages", "organizer", "nothing"], parts: parts, hasPC: false).map(\.id), ["organizer"])
    }

    func testTheStoredListRoundTripsAndNothingChosenIsOrganizer() {
        XCTAssertEqual(PartsSelection.decode(nil), ["organizer"])
        XCTAssertEqual(PartsSelection.decode(""), [])
        XCTAssertEqual(PartsSelection.decode(PartsSelection.encode(["a", "b"])), ["a", "b"])
    }

    // The real shape of /look.json "parts" (fingus_core_parts.parts(): name, icon, colour, hex, privacy; PARTS has 19 entries, 17 with a group), invented ids kept small.
    private let lookJSON = """
    {"tokens": {}, "parts": {
      "messages": {"name": "Chats", "icon": "chat", "colour": "mint", "group": "people", "hex": "#9ee0c0", "privacy": "open"},
      "organizer": {"name": "Organizer", "icon": "check", "colour": "lime", "group": "day", "hex": "#dfe35a", "privacy": "open"},
      "photos": {"name": "Photos", "icon": "photos", "colour": "lavender", "group": "media", "hex": "#cdb6ee", "privacy": "open"},
      "boards": {"name": "Boards", "icon": "board", "colour": "lavender", "group": "place", "hex": "#cdb6ee", "privacy": "locked"},
      "needs": {"name": "Needs you", "icon": "bell", "colour": "coral", "hex": "#f0a78f", "privacy": "open"}
    }}
    """

    func testCorePartsAreReadFromLookJSON() throws {
        let core = try XCTUnwrap(PartCatalog.decodeCore(Data(lookJSON.utf8)))
        XCTAssertEqual(core.map(\.id), ["boards", "messages", "organizer", "photos"])       // sorted by name; Home's own "needs" is not a screen
        XCTAssertTrue(try XCTUnwrap(core.first { $0.id == "boards" }).locked)
        XCTAssertEqual(try XCTUnwrap(core.first { $0.id == "photos" }).root, .web)
        XCTAssertEqual(try XCTUnwrap(core.first { $0.id == "photos" }).needs, .pcOnly)
        XCTAssertEqual(try XCTUnwrap(core.first { $0.id == "organizer" }).needs, .phoneOk)
        XCTAssertEqual(try XCTUnwrap(core.first { $0.id == "organizer" }).root, .organizer)
        XCTAssertNil(PartCatalog.decodeCore(Data("not json".utf8)))
    }

    func testWithNoListFromCoreThePhoneOffersItsOwnPartsAndCoreAddsTheRest() throws {
        XCTAssertEqual(PartCatalog.merged(core: nil).map(\.id), ["organizer", "messages", "location"])
        let core = try XCTUnwrap(PartCatalog.decodeCore(Data(lookJSON.utf8)))
        XCTAssertEqual(PartCatalog.merged(core: core).map(\.id), ["organizer", "messages", "location", "boards", "photos"])
    }
}
