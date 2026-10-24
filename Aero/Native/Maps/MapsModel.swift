import Foundation
import CoreLocation

// The Location part's data and words, with no screen and no map in them. Read-only: this shows what the web app's Location screen shows
// (projects/aero/design__location_ui_2026-10-06.md), from the same routes (aero_web.py: GET private/location, GET private/location/day?day=,
// GET private/location/map/info.json). Nothing here writes to Core, and nothing here knows a host: the address is the one the person gave the app.
//
// Reuse: the shapes mirror Core's own (fingus_core_location.py `now`, `day`, `timeline`, `places`); the words mirror the web page's
// (locationWhere, locationKm, locationSpan, locationLong, locationDayName). Searched for an existing Swift Location model: none in aero-ios.

// MARK: what the routes answer

/// A number that Core's SQLite rows send as 0 or 1 and its Python sends as true or false.
struct MapsFlag: Decodable, Equatable {
    var on: Bool
    init(_ on: Bool) { self.on = on }
    init(from decoder: Decoder) throws {
        let one = try decoder.singleValueContainer()
        if let b = try? one.decode(Bool.self) { on = b }
        else if let n = try? one.decode(Int.self) { on = n != 0 }
        else { on = false }
    }
}

struct MapsHomeState: Decodable, Equatable {
    var inside: MapsFlag?
    var since: Double?
}

/// Where she is now (`/location/now` at the everything level, as the overview carries it).
struct MapsNow: Decodable, Equatable {
    var known: Bool
    var at: Double?
    var age: Double?
    var lat: Double?
    var lon: Double?
    var acc: Double?
    var place: String?
    var city: String?
    var homeKm: Double?
    var home: MapsHomeState?
    enum CodingKeys: String, CodingKey { case known, at, age, lat, lon, acc, place, city, home; case homeKm = "home_km" }

    var coordinate: CLLocationCoordinate2D? {
        guard known, let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// A place's building outline: Core's `shape` ({"kind": "building", "ring": [[lat, lon], ...], "source"}), made by `fingus_core_location.py`
/// `clean_shape` (3 to SHAPE_MAX_POINTS corners, not crossing itself) and kept as Systems/PlaceShape.lean's shape. A place with none is a circle.
struct MapsShape: Decodable, Equatable {
    var kind: String
    var ring: [[Double]]
    var source: String?
}

/// One of her places: Core's `places` row.
struct MapsPlace: Decodable, Identifiable, Equatable {
    var id: String
    var name: String
    var lat: Double
    var lon: Double
    var rad: Double
    var home: MapsFlag?
    var source: String?
    /// The building's outline when it has one (PlaceShape.lean: the shape decides home, and `rad` is only the size of the region the phone is
    /// told to wake up for); nil for a circle.
    var shape: MapsShape?
    var isHome: Bool { home?.on ?? false }
    /// The outline's corners as map points, only when it is a building of three or more corners that are real places; nil otherwise, so the
    /// place keeps its circle. The closing corner, when the ring repeats its first, is dropped (the drawing closes it itself).
    var outline: [CLLocationCoordinate2D]? {
        guard let shape, shape.kind == "building" else { return nil }
        var corners: [CLLocationCoordinate2D] = []
        for q in shape.ring {
            guard q.count == 2, (-90.0...90.0).contains(q[0]), (-180.0...180.0).contains(q[1]) else { return nil }
            corners.append(CLLocationCoordinate2D(latitude: q[0], longitude: q[1]))
        }
        if corners.count > 1, let a = corners.first, let b = corners.last, a.latitude == b.latitude, a.longitude == b.longitude { corners.removeLast() }
        return corners.count >= 3 ? corners : nil
    }
    var hasShape: Bool { outline != nil }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

/// One entry of the day: a visit (a place and when) or a trip (the move between two visits). Core's `timeline`.
struct MapsStop: Decodable, Equatable, Identifiable {
    var kind: String
    var from: Double
    var to: Double
    var lat: Double?
    var lon: Double?
    var place: String?
    var city: String?
    var homeKm: Double?
    var km: Double?
    var id: String { "\(kind)-\(from)" }
    var isTrip: Bool { kind == "trip" }
    enum CodingKeys: String, CodingKey { case kind, from, to, lat, lon, place, city, km; case homeKm = "home_km" }
}

/// One point of the day's path: [time, lat, lon].
struct MapsPoint: Equatable {
    var time: Double
    var lat: Double
    var lon: Double
}

/// One day: Core's `day` (the stays are not shown; the timeline and the path are).
struct MapsDay: Decodable, Equatable {
    var day: String
    var timeline: [MapsStop]
    var path: [MapsPoint]
    enum CodingKeys: String, CodingKey { case day, timeline, path }
    init(day: String, timeline: [MapsStop], path: [MapsPoint]) { self.day = day; self.timeline = timeline; self.path = path }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        timeline = (try? c.decode([MapsStop].self, forKey: .timeline)) ?? []
        let raw = (try? c.decode([[Double]].self, forKey: .path)) ?? []
        path = raw.compactMap { $0.count >= 3 ? MapsPoint(time: $0[0], lat: $0[1], lon: $0[2]) : nil }
    }
}

struct MapsSettings: Decodable, Equatable {
    var paused: Bool?
}

/// `GET private/location`: now, today, her places, whether recording is paused.
struct MapsOverview: Decodable, Equatable {
    var now: MapsNow
    var today: MapsDay
    var places: [MapsPlace]
    var settings: MapsSettings?
}

/// `GET private/location/map/info.json`, the two things the screen says about the map: whether the PC is fetching it, and whether the VPN route it
/// fetches through is down.
struct MapsInfo: Decodable, Equatable {
    struct Tiles: Decodable, Equatable { var unreachable: Bool? }
    var fetching: String?
    var tiles: Tiles?
}

// MARK: words (the web page's, as plain functions)

enum MapsText {
    /// "7:05 AM" in the phone's own time zone and language.
    static func clock(_ time: Double, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: Date(timeIntervalSince1970: time))
    }

    static func coords(_ lat: Double, _ lon: Double) -> String { String(format: "%.5f, %.5f", lat, lon) }

    /// One of her places, else the city, else the coordinates.
    static func whereIs(place: String?, city: String?, lat: Double?, lon: Double?) -> String {
        if let place, !place.isEmpty { return place }
        if let city, !city.isEmpty { return city }
        if let lat, let lon { return coords(lat, lon) }
        return ""
    }

    /// "1.2 km from home", only for a spot that is not one of her places.
    static func fromHome(_ km: Double?, place: String?) -> String {
        guard let km, place == nil || place?.isEmpty == true else { return "" }
        return String(format: "%.1f km from home", km)
    }

    /// "7:05 AM to 8:10 AM", or one time when it was under a minute.
    static func span(_ a: Double, _ b: Double, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        b - a < 60 ? clock(a, timeZone: timeZone, locale: locale)
                   : clock(a, timeZone: timeZone, locale: locale) + " to " + clock(b, timeZone: timeZone, locale: locale)
    }

    /// "5 min", "1 h", "1 h 5 min".
    static func long(_ seconds: Double) -> String {
        let m = max(1, Int((seconds / 60).rounded()))
        if m < 60 { return "\(m) min" }
        return "\(m / 60) h" + (m % 60 != 0 ? " \(m % 60) min" : "")
    }

    /// Core counts a fix as fresh for 15 minutes.
    static let freshSeconds: Double = 15 * 60

    static func isFresh(_ now: MapsNow) -> Bool { (now.age ?? .infinity) < freshSeconds }

    /// The big line of the head: where she is.
    static func headline(_ now: MapsNow) -> String {
        guard now.known else { return "Nothing from your phone yet" }
        return whereIs(place: now.place, city: now.city, lat: now.lat, lon: now.lon)
    }

    /// The small line under it: "Now · 7:05 AM · within 20 m · 1.2 km from home".
    static func subline(_ now: MapsNow, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        guard now.known else { return "Set up OwnTracks in Aero to start" }
        var parts = [(isFresh(now) ? "Now" : "Last seen") + " · " + clock(now.at ?? 0, timeZone: timeZone, locale: locale)]
        if let acc = now.acc, acc > 0 { parts.append("within \(Int(acc.rounded())) m") }
        let away = fromHome(now.homeKm, place: now.place)
        if !away.isEmpty { parts.append(away) }
        return parts.joined(separator: " · ")
    }

    /// "Home since 7:05 AM" / "Away since 8:10 AM", or nil when Core has no home to compare with.
    static func homeChip(_ now: MapsNow, timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard now.known, let inside = now.home?.inside else { return nil }
        let since = now.home?.since.map { " since " + clock($0, timeZone: timeZone, locale: locale) } ?? ""
        return (inside.on ? "Home" : "Away") + since
    }

    // days

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// A day key moved by whole days (noon, so a clock change cannot move it a day).
    static func shift(_ key: String, by days: Int, calendar: Calendar = .current) -> String {
        guard let d = date(of: key, calendar: calendar), let moved = calendar.date(byAdding: .day, value: days, to: d) else { return key }
        return dayKey(moved, calendar: calendar)
    }

    static func date(of key: String, calendar: Calendar = .current) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2], hour: 12))
    }

    /// "Today", "Yesterday", or "Mon, 5 Oct".
    static func dayName(_ key: String, today: String, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if key == today { return "Today" }
        if key == shift(today, by: -1, calendar: calendar) { return "Yesterday" }
        guard let d = date(of: key, calendar: calendar) else { return key }
        let f = DateFormatter()
        f.locale = locale
        f.calendar = calendar
        f.setLocalizedDateFormatFromTemplate("EEEdMMM")
        return f.string(from: d)
    }

    // the sheet's rows

    struct Row: Equatable, Identifiable {
        var id: String
        var title: String
        var value: String
        var note: String
        /// Where the map goes when the row is tapped.
        var target: Target
        var isTrip = false
        var isHome = false
    }

    enum Target: Equatable {
        case visit(lat: Double, lon: Double)
        case trip(from: Double, to: Double)
        case place(lat: Double, lon: Double)
        case none
    }

    /// The day as rows, the latest first (as the web page lists it).
    static func timelineRows(_ day: MapsDay, places: [MapsPlace], timeZone: TimeZone = .current, locale: Locale = .current) -> [Row] {
        day.timeline.reversed().map { x in
            if x.isTrip {
                let secs = x.to - x.from
                return Row(id: x.id, title: "Moving", value: secs >= 60 ? long(secs) : "",
                           note: (x.km ?? 0) > 0 ? String(format: "%.1f km", x.km ?? 0) : "", target: .trip(from: x.from, to: x.to), isTrip: true)
            }
            let mine = places.first { $0.name == x.place }
            let target: Target = (x.lat != nil && x.lon != nil) ? .visit(lat: x.lat ?? 0, lon: x.lon ?? 0) : .none
            return Row(id: x.id, title: whereIs(place: x.place, city: x.city, lat: x.lat, lon: x.lon),
                       value: span(x.from, x.to, timeZone: timeZone, locale: locale), note: fromHome(x.homeKm, place: x.place),
                       target: target, isHome: mine?.isHome ?? false)
        }
    }

    /// Metres between two points on the Earth (haversine, a sphere of 6371000 m, as the web page's `locationMetres`).
    static func metres(_ a1: Double, _ o1: Double, _ a2: Double, _ o2: Double) -> Double {
        let r = Double.pi / 180
        let x = pow(sin((a2 - a1) * r / 2), 2) + cos(a1 * r) * cos(a2 * r) * pow(sin((o2 - o1) * r / 2), 2)
        return 6371000 * 2 * asin(min(1, sqrt(x)))
    }

    /// Her places: home first, then A to Z, each with how far it is or "Here".
    static func placeRows(_ places: [MapsPlace], now: MapsNow) -> [Row] {
        let sorted = places.sorted {
            if $0.isHome != $1.isHome { return $0.isHome }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return sorted.map { p in
            var value = ""
            if p.isHome { value = "Home" }
            else if now.known, let lat = now.lat, let lon = now.lon {
                let m = metres(lat, lon, p.lat, p.lon)
                value = m <= p.rad ? "Here" : String(format: "%.1f km", m / 1000)
            }
            return Row(id: p.id, title: p.name, value: value,
                       note: (p.hasShape ? "Wake-up size \(Int(p.rad.rounded())) m" : "\(Int(p.rad.rounded())) m around it") + (p.source == "phone" ? " · From OwnTracks" : ""),
                       target: .place(lat: p.lat, lon: p.lon), isHome: p.isHome)
        }
    }

    static let creditLine = "© OpenStreetMap contributors · Protomaps"
    static let needsPC = "Maps need your PC"
    static let vpnDown = "The rest of the map needs the VPN route"
    static let gettingMap = "Getting the map…"
}
