import Foundation
import CoreLocation

/// What is drawn over the map, as plain data (the web page's `locationOverlays`): her places with their areas, the day's path, its visits, and
/// where she is now with its accuracy. Pure, so a test can read it.
struct MapsOverlay: Equatable {
    var places: [MapsPlace] = []
    var path: [MapsPoint] = []
    var visits: [CLLocationCoordinate2D] = []
    var here: CLLocationCoordinate2D?
    var hereAccuracy: Double?
    var hereOld = false

    static func == (a: MapsOverlay, b: MapsOverlay) -> Bool {
        a.places == b.places && a.path == b.path && a.hereAccuracy == b.hereAccuracy && a.hereOld == b.hereOld
            && a.visits.count == b.visits.count && zip(a.visits, b.visits).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
            && a.here?.latitude == b.here?.latitude && a.here?.longitude == b.here?.longitude
    }

    /// From the answers. Her dot and its accuracy are drawn only on today's map, as the web page does.
    static func make(overview: MapsOverview?, day: MapsDay?, isToday: Bool) -> MapsOverlay {
        guard let overview else { return MapsOverlay() }
        var o = MapsOverlay()
        o.places = overview.places
        o.path = day?.path ?? []
        o.visits = (day?.timeline ?? []).filter { !$0.isTrip }.compactMap { x in
            guard let lat = x.lat, let lon = x.lon else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        if isToday, let c = overview.now.coordinate {
            o.here = c
            o.hereAccuracy = (overview.now.acc ?? 0) > 0 ? overview.now.acc : nil
            o.hereOld = !MapsText.isFresh(overview.now)
        }
        return o
    }

    /// The outline drawn for a place: its building, closed, when it has one; otherwise the circle of its `rad` (a place without a shape keeps its
    /// circle). Never both: a building's `rad` is only the wake-up size, not an area on the map.
    static func area(of place: MapsPlace) -> [CLLocationCoordinate2D] {
        if let corners = place.outline, let first = corners.first { return corners + [first] }
        return circle(place.coordinate, metres: place.rad)
    }

    /// A circle of `metres` round a point, as 48 steps (the web page's `locationCircle`).
    static func circle(_ centre: CLLocationCoordinate2D, metres: Double) -> [CLLocationCoordinate2D] {
        (0...48).map { i in
            let a = Double(i) / 48 * 2 * Double.pi
            return CLLocationCoordinate2D(latitude: centre.latitude + metres * cos(a) / 110540,
                                          longitude: centre.longitude + metres * sin(a) / (111320 * cos(centre.latitude * Double.pi / 180)))
        }
    }
}
