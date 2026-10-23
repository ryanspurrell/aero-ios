import XCTest
import CoreLocation
@testable import Aero

/// The Location part: its data, its words, its style, and the one thing it must never do, which is to ask any host but the server the app was given.
/// Every place, coordinate, name and address here is invented (`pc.example.test` is the stand-in for her PC).
/// Nothing is drawn by these tests: MapLibre itself is not exercised; its style document and the requests that would be made for it are.
final class MapsTests: XCTestCase {
    private let server = URL(string: "https://pc.example.test")!
    private let gregorian = Calendar(identifier: .gregorian)
    private let utc = TimeZone(identifier: "UTC")!

    // MARK: a stand-in server that records what reaches it

    /// Answers by path, and writes down each request it is given. Only requests the network guard let through reach it.
    final class StubServer: URLProtocol {
        static let lock = NSLock()
        static var seen: [URLRequest] = []
        static var answers: [String: (Int, String)] = [:]

        static func reset(_ answers: [String: (Int, String)] = [:]) {
            lock.lock(); defer { lock.unlock() }
            seen = []
            self.answers = answers
        }
        static var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return seen }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            StubServer.lock.lock()
            StubServer.seen.append(request)
            let key = (request.url?.path ?? "") + ((request.url?.query).map { "?" + $0 } ?? "")
            let answer = StubServer.answers[key] ?? (404, "{}")
            StubServer.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(answer.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
    }

    private func session() -> URLSession { URLSession(configuration: MapsNetwork.sessionConfiguration(extra: [StubServer.self])) }

    private func cookie() -> HTTPCookie {
        HTTPCookie(properties: [.domain: "pc.example.test", .path: "/", .name: "aero", .value: "invented-ticket", .secure: "TRUE"])!
    }

    private let overviewJSON = """
    {"now":{"known":true,"at":1790000000,"age":120,"lat":12.3456,"lon":45.6789,"acc":25,"place":"Library","city":null,"home_km":1.2,
            "home":{"inside":false,"since":1789990000,"by":"enter"},"paused":false},
     "today":{"day":"2026-10-22","stays":[],"path":[[1789999000,12.34,45.67],[1790000000,12.3456,45.6789]],
       "timeline":[{"kind":"visit","from":1789980000,"to":1789990000,"lat":12.3,"lon":45.6,"points":3,"place":"Home","city":null,"home_km":0.0},
                   {"kind":"trip","from":1789990000,"to":1789999000,"km":1.2},
                   {"kind":"visit","from":1789999000,"to":1790000000,"lat":12.3456,"lon":45.6789,"points":1,"place":"Library","city":null,"home_km":1.2}],
       "transitions":[]},
     "places":[{"id":"a-home","name":"Home","lat":12.3,"lon":45.6,"rad":150,"home":1,"source":"phone"},
               {"id":"a-library","name":"Library","lat":12.3456,"lon":45.6789,"rad":60.0,"home":0,"source":"aero"}],
     "settings":{"paused":false,"cloud":"place"},"counts":{},"door":"invented"}
    """
    private let dayJSON = """
    {"day":"2026-10-21","stays":[],"path":[[1789900000,12.31,45.61],[1789901000,12.32,45.62]],
     "timeline":[{"kind":"visit","from":1789890000,"to":1789901000,"lat":12.31,"lon":45.61,"points":2,"place":null,"city":"Invented City","home_km":3.4}],"transitions":[]}
    """

    // MARK: the data and the words

    func testOverviewIsReadFromTheRealShape() throws {
        let o = try JSONDecoder().decode(MapsOverview.self, from: Data(overviewJSON.utf8))
        XCTAssertEqual(o.places.map(\.name), ["Home", "Library"])
        XCTAssertTrue(o.places[0].isHome)            // SQLite sends home as 1, not true
        XCTAssertFalse(o.places[1].isHome)
        XCTAssertEqual(o.today.timeline.map(\.kind), ["visit", "trip", "visit"])
        XCTAssertEqual(o.today.path.count, 2)
        XCTAssertEqual(o.today.path[1], MapsPoint(time: 1790000000, lat: 12.3456, lon: 45.6789))
        XCTAssertEqual(o.now.coordinate?.latitude, 12.3456)
        XCTAssertEqual(o.now.home?.inside?.on, false)
    }

    func testNothingFromThePhoneYetReadsAndSays() throws {
        let now = try JSONDecoder().decode(MapsNow.self, from: Data(#"{"known":false,"paused":false}"#.utf8))
        XCTAssertNil(now.coordinate)
        XCTAssertEqual(MapsText.headline(now), "Nothing from your phone yet")
        XCTAssertNil(MapsText.homeChip(now))
    }

    func testDurationsAndSpans() {
        XCTAssertEqual(MapsText.long(10), "1 min")
        XCTAssertEqual(MapsText.long(5 * 60), "5 min")
        XCTAssertEqual(MapsText.long(60 * 60), "1 h")
        XCTAssertEqual(MapsText.long(65 * 60), "1 h 5 min")
        let one = MapsText.span(1790000000, 1790000030, timeZone: utc, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(one, MapsText.clock(1790000000, timeZone: utc, locale: Locale(identifier: "en_US")))
        XCTAssertTrue(MapsText.span(1790000000, 1790003600, timeZone: utc, locale: Locale(identifier: "en_US")).contains(" to "))
    }

    func testDaysStepByWholeDaysAndAreNamed() {
        XCTAssertEqual(MapsText.shift("2026-10-31", by: 1, calendar: gregorian), "2026-11-01")
        XCTAssertEqual(MapsText.shift("2026-03-01", by: -1, calendar: gregorian), "2026-02-28")
        XCTAssertEqual(MapsText.dayName("2026-10-22", today: "2026-10-22", calendar: gregorian), "Today")
        XCTAssertEqual(MapsText.dayName("2026-10-21", today: "2026-10-22", calendar: gregorian), "Yesterday")
        XCTAssertFalse(MapsText.dayName("2026-10-05", today: "2026-10-22", calendar: gregorian, locale: Locale(identifier: "en_US")).isEmpty)
    }

    func testTheHeadNamesThePlaceTheTimeAndTheDistanceFromHome() throws {
        let o = try JSONDecoder().decode(MapsOverview.self, from: Data(overviewJSON.utf8))
        XCTAssertEqual(MapsText.headline(o.now), "Library")
        let line = MapsText.subline(o.now, timeZone: utc, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(line.hasPrefix("Now · "), line)                 // age 120 s: fresh
        XCTAssertTrue(line.contains("within 25 m"), line)
        XCTAssertFalse(line.contains("km from home"), line)           // a place of hers is named; its distance from home is not added
        XCTAssertTrue(try XCTUnwrap(MapsText.homeChip(o.now, timeZone: utc, locale: Locale(identifier: "en_US"))).hasPrefix("Away since "))
        var old = o.now
        old.age = 3600
        XCTAssertTrue(MapsText.subline(old, timeZone: utc).hasPrefix("Last seen · "))
        old.place = nil
        old.city = nil
        XCTAssertEqual(MapsText.headline(old), "12.34560, 45.67890")  // no place and no city: the coordinates
    }

    func testTheTimelineIsListedLatestFirstAndEveryRowIsText() throws {
        let o = try JSONDecoder().decode(MapsOverview.self, from: Data(overviewJSON.utf8))
        let rows = MapsText.timelineRows(o.today, places: o.places, timeZone: utc, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(rows.map(\.title), ["Library", "Moving", "Home"])
        XCTAssertEqual(rows[1].value, "2 h 30 min")
        XCTAssertEqual(rows[1].note, "1.2 km")
        XCTAssertEqual(rows[1].target, .trip(from: 1789990000, to: 1789999000))
        XCTAssertTrue(rows[2].isHome)
        XCTAssertEqual(rows[0].target, .visit(lat: 12.3456, lon: 45.6789))
        let away = try JSONDecoder().decode(MapsDay.self, from: Data(dayJSON.utf8))
        let city = MapsText.timelineRows(away, places: o.places)
        XCTAssertEqual(city.map(\.title), ["Invented City"])
        XCTAssertEqual(city[0].note, "3.4 km from home")
    }

    func testPlacesListHomeFirstThenAToZWithHowFar() throws {
        let o = try JSONDecoder().decode(MapsOverview.self, from: Data(overviewJSON.utf8))
        let rows = MapsText.placeRows(o.places, now: o.now)
        XCTAssertEqual(rows.map(\.title), ["Home", "Library"])
        XCTAssertEqual(rows[0].value, "Home")
        XCTAssertEqual(rows[1].value, "Here")                       // she is at the Library's own point, inside its 60 m
        XCTAssertEqual(rows[0].note, "150 m around it · From OwnTracks")
        XCTAssertEqual(rows[1].note, "60 m around it")
        var elsewhere = o.now
        elsewhere.lat = 12.4
        XCTAssertTrue(MapsText.placeRows(o.places, now: elsewhere)[1].value.hasSuffix(" km"))
    }

    func testAPlaceCirclePointsAreItsRadiusFromItsMiddle() {
        let c = CLLocationCoordinate2D(latitude: 12.3, longitude: 45.6)
        let ring = MapsOverlay.circle(c, metres: 150)
        XCTAssertEqual(ring.count, 49)
        for p in ring { XCTAssertEqual(MapsText.metres(c.latitude, c.longitude, p.latitude, p.longitude), 150, accuracy: 3) }
    }

    func testHerDotIsDrawnOnTodayOnly() throws {
        let o = try JSONDecoder().decode(MapsOverview.self, from: Data(overviewJSON.utf8))
        XCTAssertNotNil(MapsOverlay.make(overview: o, day: o.today, isToday: true).here)
        XCTAssertNil(MapsOverlay.make(overview: o, day: o.today, isToday: false).here)
        XCTAssertEqual(MapsOverlay.make(overview: o, day: o.today, isToday: true).visits.count, 2)
        XCTAssertEqual(MapsOverlay.make(overview: nil, day: nil, isToday: true), MapsOverlay())
    }

    // MARK: the style names only the server

    func testTheStyleAsksOnlyTheServerForEverything() throws {
        for night in [false, true] {
            let layers = try XCTUnwrap(MapsStyle.bundledLayers(night: night), "the bundled layers are in the app")
            let style = try XCTUnwrap(MapsStyle.json(server: server, night: night, layers: layers))
            let addresses = MapsStyle.addresses(in: style)
            XCTAssertEqual(addresses.count, 3, "tiles, letters and symbols are the only addresses the style holds")
            for url in addresses {
                XCTAssertTrue(MapsNetwork.allows(url, origin: MapsOrigin(server)), "\(url.host ?? "?") is not the server")
                XCTAssertTrue(url.path.hasPrefix("/private/location/map/"), url.path)
            }
            let text = String(decoding: style, as: UTF8.self)
            XCTAssertFalse(text.contains("openstreetmap"), "no outside map service is named")
            XCTAssertFalse(text.contains("protomaps.com"))
            XCTAssertFalse(text.contains("maplibre.org"))
            XCTAssertTrue(text.contains("sprites/" + (night ? "dark" : "light")))
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: style) as? [String: Any])
            XCTAssertEqual((parsed["layers"] as? [Any])?.count, 71)
        }
    }

    func testTheServersPathAndPortStayOnTheServer() {
        let withPort = URL(string: "https://pc.example.test:8443/aero/")!
        let base = MapsStyle.mapBase(withPort)
        XCTAssertEqual(base, "https://pc.example.test:8443/aero/private/location/map/")
        XCTAssertTrue(MapsNetwork.allows(URL(string: base + "tiles/3/1/2.mvt"), origin: MapsOrigin(withPort)))
        XCTAssertFalse(MapsNetwork.allows(URL(string: "https://pc.example.test/x"), origin: MapsOrigin(withPort)), "another port is another origin")
    }

    // MARK: no request goes to any host but the server

    func testRequestsToAnyOtherHostFailBeforeTheyAreSent() async {
        StubServer.reset(["/private/location/map/tiles/1/1/1.mvt": (200, "{}")])
        MapsNetwork.use(base: server, cookieHeader: nil)
        let s = session()
        let elsewhere = [
            "https://tile.openstreetmap.example/1/1/1.png",
            "https://build.protomaps.example/20261022.pmtiles",
            "https://geocode.example.test/search?q=x",
            "https://fonts.example.test/Noto.pbf",
            "http://pc.example.test/private/location",                 // the same host over another scheme
            "https://pc.example.test:8443/private/location",           // the same host on another port
            "https://pc.example.test.evil.example/private/location",   // a host that only starts like it
        ]
        for text in elsewhere {
            do {
                _ = try await s.data(from: URL(string: text)!)
                XCTFail("\(text) was not refused")
            } catch {
                XCTAssertEqual((error as NSError).domain, "FingusMaps", text)
            }
        }
        // the server itself goes through
        let (_, response) = try! await s.data(from: URL(string: "https://pc.example.test/private/location/map/tiles/1/1/1.mvt")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(StubServer.requests.compactMap { $0.url?.host }, ["pc.example.test"], "only the server's own request reached the network")
        XCTAssertEqual(MapsNetwork.blockedHosts.count, elsewhere.count)
    }

    func testWithNoServerAddressNothingIsAllowed() async {
        StubServer.reset(["/private/location": (200, overviewJSON)])
        MapsNetwork.use(base: nil, cookieHeader: nil)
        do {
            _ = try await session().data(from: URL(string: "https://pc.example.test/private/location")!)
            XCTFail("a request went out with no server set")
        } catch {
            XCTAssertEqual((error as NSError).domain, "FingusMaps")
        }
        XCTAssertTrue(StubServer.requests.isEmpty)
    }

    func testTheThreeReadsGoToTheServerWithItsCookieAndNothingElse() async throws {
        StubServer.reset(["/private/location": (200, overviewJSON),
                          "/private/location/day?day=2026-10-21": (200, dayJSON),
                          "/private/location/map/info.json": (200, #"{"fetching":null,"tiles":{"unreachable":true}}"#)])
        let api = MapsAPI(session: session(), base: { self.server }, cookies: { _ in [self.cookie()] })
        let o = try await api.overview()
        let d = try await api.day("2026-10-21")
        let i = try await api.info()
        XCTAssertEqual(o.places.count, 2)
        XCTAssertEqual(d.timeline.count, 1)
        XCTAssertEqual(i.tiles?.unreachable, true)
        let seen = StubServer.requests
        XCTAssertEqual(seen.map { ($0.url?.path ?? "") + (($0.url?.query).map { "?" + $0 } ?? "") },
                       ["/private/location", "/private/location/day?day=2026-10-21", "/private/location/map/info.json"])
        XCTAssertEqual(Set(seen.compactMap { $0.url?.host }), ["pc.example.test"])
        XCTAssertTrue(seen.allSatisfy { ($0.httpMethod ?? "GET") == "GET" }, "the part only reads")
        XCTAssertTrue(seen.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "aero=invented-ticket" })
        XCTAssertTrue(MapsNetwork.blockedHosts.isEmpty)
    }

    func testTheStoreLoadsTheDayAndStepsBackWithoutAskingAnyoneElse() async throws {
        StubServer.reset(["/private/location": (200, overviewJSON),
                          "/private/location/day?day=2026-10-21": (200, dayJSON),
                          "/private/location/map/info.json": (200, #"{"fetching":"area","tiles":{}}"#)])
        let api = MapsAPI(session: session(), base: { self.server }, cookies: { _ in [self.cookie()] })
        let store = await MainActor.run { MapsStore(api: api, hasAddress: { true }) }
        await store.load()
        await store.step(-1)
        await store.step(1)                          // back to today: no request, the overview already holds it
        await store.step(1)                          // tomorrow: refused, there is nothing after today
        let (phase, key, says, today) = await MainActor.run { (store.phase, store.dayKey, store.mapSays, store.isToday) }
        XCTAssertEqual(phase, .ready)
        XCTAssertEqual(key, "2026-10-22")
        XCTAssertTrue(today)
        XCTAssertEqual(says, MapsText.gettingMap)
        XCTAssertEqual(StubServer.requests.count, 3)
        XCTAssertEqual(Set(StubServer.requests.compactMap { $0.url?.host }), ["pc.example.test"])
        XCTAssertTrue(MapsNetwork.blockedHosts.isEmpty)
    }

    // MARK: refusals and the no-PC case

    func testTheServersRefusalsAreSaidPlainly() {
        XCTAssertEqual(MapsAPI.failure(status: 403, data: Data(#"{"error":"Open Aero through your tailnet to see your location","open":"https://x.example.test"}"#.utf8)), .needsTailnet)
        XCTAssertEqual(MapsAPI.failure(status: 401, data: Data("{}".utf8)), .notSignedIn)
        XCTAssertEqual(MapsAPI.failure(status: 400, data: Data(#"{"error":"a day as YYYY-MM-DD"}"#.utf8)), .server("a day as YYYY-MM-DD"))
        XCTAssertNil(MapsAPI.failure(status: 200, data: Data()))
    }

    func testWithNoPcThePartSaysMapsNeedThePc() async {
        StubServer.reset()
        let api = MapsAPI(session: session(), base: { nil }, cookies: { _ in [] })
        do { _ = try await api.overview(); XCTFail("asked with no address") } catch { XCTAssertEqual(error as? MapsAPI.Failure, .noAddress) }
        XCTAssertTrue(StubServer.requests.isEmpty)
        XCTAssertEqual(MapsAPI.Failure.noAddress.words, "Maps need your PC")
        let store = await MainActor.run { MapsStore(api: api, hasAddress: { false }) }
        await store.load()
        let phase = await MainActor.run { store.phase }
        XCTAssertEqual(phase, .needsPC)
        // and the chooser says so before it is added
        let location = PartCatalog.merged(core: nil).first { $0.id == "location" }
        XCTAssertEqual(location?.root, .maps)
        XCTAssertEqual(location?.needs, .pcOnly)
        XCTAssertFalse(PartsSelection.offered(try! XCTUnwrap(location), hasPC: false))
        XCTAssertEqual(PartsSelection.tiles(added: ["location"], parts: PartCatalog.merged(core: nil), hasPC: false).count, 0)
    }
}
