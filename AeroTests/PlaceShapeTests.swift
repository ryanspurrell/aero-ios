import XCTest
import CoreLocation
@testable import Aero

/// A place is the building's shape (Systems/PlaceShape.lean; Core's `shape` on a place, fingus_core_location.py `clean_shape`): the map draws the
/// outline when the place has one and keeps the circle when it does not, and `rad` of a place with a shape is only the size of the region the phone
/// wakes up for, so it is said as "Wake-up size". All coordinates are invented.
final class PlaceShapeTests: XCTestCase {
    // a small building and a plain circle place; the ring is [lat, lon] pairs, not closed (Core keeps the corners as given)
    private let placesJSON = """
    [{"id":"home","name":"Home","lat":12.3000,"lon":45.6000,"rad":150,"home":1,"source":"phone",
      "shape":{"kind":"building","ring":[[12.30010,45.59990],[12.30010,45.60010],[12.29990,45.60010],[12.29990,45.59990]],"source":"map"}},
     {"id":"lib","name":"Library","lat":12.3456,"lon":45.6789,"rad":60.0,"home":0,"source":"aero","shape":null},
     {"id":"old","name":"Old","lat":12.4,"lon":45.7,"rad":80,"home":0,"source":"aero"}]
    """

    private func places() throws -> [MapsPlace] { try JSONDecoder().decode([MapsPlace].self, from: Data(placesJSON.utf8)) }

    func testAShapeIsReadAndAPlaceWithNoneStaysACircle() throws {
        let p = try places()
        XCTAssertTrue(p[0].hasShape)
        XCTAssertEqual(p[0].shape?.kind, "building")
        XCTAssertEqual(p[0].outline?.count, 4)
        XCTAssertFalse(p[1].hasShape)                       // "shape": null
        XCTAssertFalse(p[2].hasShape)                       // no shape at all (an older Core)
    }

    func testTheOutlineIsDrawnClosedInsteadOfTheCircle() throws {
        let home = try XCTUnwrap(try places().first)
        let area = MapsOverlay.area(of: home)
        XCTAssertEqual(area.count, 5)                       // four corners and the first again: a closed ring the fill can use
        XCTAssertEqual(area.first?.latitude, area.last?.latitude)
        XCTAssertEqual(area.first?.longitude, area.last?.longitude)
        XCTAssertEqual(area[0].latitude, 12.30010, accuracy: 1e-9)
        XCTAssertEqual(area[0].longitude, 45.59990, accuracy: 1e-9)
        // not the 150 m circle: every point is within a few metres of the middle, where the circle's are 150 m out
        for q in area { XCTAssertLessThan(MapsText.metres(home.lat, home.lon, q.latitude, q.longitude), 30) }
    }

    func testAPlaceWithoutAShapeKeepsItsCircle() throws {
        let lib = try places()[1]
        let area = MapsOverlay.area(of: lib)
        XCTAssertEqual(area.count, 49)
        for q in area { XCTAssertEqual(MapsText.metres(lib.lat, lib.lon, q.latitude, q.longitude), 60, accuracy: 2) }
    }

    func testAShapeThatCannotBeDrawnFallsBackToTheCircle() throws {
        var home = try places()[0]
        home.shape = MapsShape(kind: "building", ring: [[12.3, 45.6], [12.31, 45.6]], source: nil)                       // two corners
        XCTAssertFalse(home.hasShape)
        XCTAssertEqual(MapsOverlay.area(of: home).count, 49)
        home.shape = MapsShape(kind: "building", ring: [[12.3, 45.6], [12.31], [12.3, 45.61]], source: nil)             // a corner that is not a pair
        XCTAssertFalse(home.hasShape)
        home.shape = MapsShape(kind: "building", ring: [[95, 45.6], [12.31, 45.6], [12.3, 45.61]], source: nil)          // not a place on Earth
        XCTAssertFalse(home.hasShape)
        home.shape = MapsShape(kind: "circle", ring: [[12.3, 45.6], [12.31, 45.6], [12.3, 45.61]], source: nil)         // a kind this app does not know
        XCTAssertFalse(home.hasShape)
    }

    func testARingThatRepeatsItsFirstCornerIsNotDrawnWithAnExtraCorner() throws {
        var home = try places()[0]
        home.shape = MapsShape(kind: "building", ring: [[12.3, 45.6], [12.31, 45.6], [12.3, 45.61], [12.3, 45.6]], source: nil)
        XCTAssertEqual(home.outline?.count, 3)
        XCTAssertEqual(MapsOverlay.area(of: home).count, 4)
    }

    func testRadIsCalledWakeUpSizeOnlyForAPlaceWithAShape() throws {
        let o = try places()
        let rows = MapsText.placeRows(o, now: MapsNow(known: false))
        let home = try XCTUnwrap(rows.first { $0.title == "Home" })
        let lib = try XCTUnwrap(rows.first { $0.title == "Library" })
        XCTAssertEqual(home.note, "Wake-up size 150 m · From OwnTracks")
        XCTAssertEqual(lib.note, "60 m around it")
    }

    func testTheOverlayCarriesTheShapeToTheMap() throws {
        let p = try places()
        var o = MapsOverlay()
        o.places = p
        XCTAssertEqual(o.places[0].shape, p[0].shape)
        var changed = o
        changed.places[0].shape = nil
        XCTAssertNotEqual(o, changed)                       // a place that gained or lost its outline is drawn again
    }
}
