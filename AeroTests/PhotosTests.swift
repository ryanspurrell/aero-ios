import XCTest
import UIKit
@testable import Aero

/// A stand-in for Aero's server: answers each path with the JSON the server code writes (PhotosFixtures), records what was asked and which
/// cookie went with it. Nothing leaves the test process.
final class PhotosStub: URLProtocol {
    static var answers: [String: (Int, Data)] = [:]
    static var asked: [URL] = []
    static var cookies: [String?] = []
    static var fail = false

    static func reset() { answers = [:]; asked = []; cookies = []; fail = false }
    static func say(_ path: String, _ json: String, status: Int = 200) { answers[path] = (status, Data(json.utf8)) }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PhotosStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        PhotosStub.asked.append(url)
        PhotosStub.cookies.append(request.value(forHTTPHeaderField: "Cookie"))
        if PhotosStub.fail { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let (status, data) = PhotosStub.answers[url.path] ?? (404, Data(#"{"error":"no such photo"}"#.utf8))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Photos without a screen: what the server's answers decode to, which routes are asked and how, how a failure becomes a state, the walk, the
/// size-capped memory cache. All names, places and ids are invented.
final class PhotosTests: XCTestCase {
    private let base = URL(string: "https://aero.invalid")!
    private let id1 = "11111111-1111-4111-8111-111111111111"

    override func setUp() { PhotosStub.reset() }

    private func api(address: URL? = URL(string: "https://aero.invalid"), cookies: [HTTPCookie] = []) -> PhotosAPI {
        PhotosAPI(session: PhotosStub.session(), address: { address }, cookies: { cookies })
    }

    private static func query(_ url: URL) -> [String: String] {
        var out: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { out[item.name] = item.value ?? "" }
        return out
    }

    private func decode<T: Decodable>(_ json: String, as: T.Type) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }

    // MARK: the server's shapes

    func testTheMonthsAnswerCarriesTheNewestMonthsItems() throws {
        let a = try decode(PhotosFixtures.months, as: PhotoMonthsAnswer.self)
        XCTAssertEqual(a.months, [PhotoMonth(month: "2026-10", count: 4), PhotoMonth(month: "2026-09", count: 1)])
        XCTAssertEqual(a.total, 5)
        XCTAssertEqual(a.first?.month, "2026-10")
        XCTAssertEqual(a.first?.items.count, 4)
    }

    func testAnItemIsReadFromEverythingTheServerSends() throws {
        let m = try decode(PhotosFixtures.october, as: PhotoMonthAnswer.self)
        XCTAssertEqual(m.items.map(\.id).first, id1)
        let plain = m.items[0], live = m.items[1], video = m.items[2], covered = m.items[3]
        XCTAssertEqual(plain.taken, "2026-10-05T12:03:09")
        XCTAssertEqual(plain.place, "Edmonton, Canada")
        XCTAssertEqual(plain.version, "f381c84a6ce4")
        XCTAssertEqual(plain.ratio, 1.5)
        XCTAssertFalse(plain.live); XCTAssertFalse(plain.video); XCTAssertFalse(plain.covered)
        XCTAssertTrue(live.live); XCTAssertTrue(live.favourite)
        XCTAssertNil(live.version)                              // no thumbnail yet: the server sends null
        XCTAssertTrue(video.video)
        XCTAssertEqual(video.ms, 12345)                         // the older Immich's "0:00:12.345000"
        XCTAssertTrue(covered.covered)                          // her cover-up setting
    }

    func testADurationInMillisecondsAndAnAnimatedPictureAreRead() throws {
        let m = try decode(PhotosFixtures.september, as: PhotoMonthAnswer.self)
        XCTAssertEqual(m.items[0].ms, 2500)
        XCTAssertTrue(m.items[0].animated)
        XCTAssertFalse(m.items[0].video)
    }

    func testAlbumsKeepANoCoverAlbumAsOne() throws {
        let a = try decode(PhotosFixtures.albums, as: PhotoAlbumsAnswer.self).albums
        XCTAssertEqual(a.map(\.name), ["Trip", "Garden"])
        XCTAssertEqual(a[0].cover, id1)
        XCTAssertEqual(a[0].count, 4)
        XCTAssertEqual(a[0].end, "2026-10-05")
        XCTAssertNil(a[1].cover)
        XCTAssertEqual(a[1].count, 0)
    }

    func testTheInfoSheetReadsWhatItShows() throws {
        let i = try decode(PhotosFixtures.info, as: PhotoInfo.self)
        XCTAssertEqual(i.name, "IMG_0001.HEIC")
        XCTAssertEqual(i.place, "Edmonton, Alberta, Canada")
        XCTAssertEqual(i.camera, "Apple iPhone 15")
        XCTAssertEqual(i.pixels, [4032, 3024])
        XCTAssertEqual(i.size, 2345678)
        XCTAssertEqual(i.albums.map(\.name), ["Trip"])
        XCTAssertEqual(i.people.map(\.name), ["Sam"])
        XCTAssertEqual(i.said, "A dog on a lawn")
    }

    func testAnEmptyOrOddAnswerStillReads() throws {
        XCTAssertEqual(try decode("{}", as: PhotoMonthsAnswer.self).months, [])
        XCTAssertEqual(try decode(#"{"month":"2026-10"}"#, as: PhotoMonthAnswer.self).items, [])
        XCTAssertEqual(try decode(#"{"id":"x"}"#, as: PhotoItem.self).ratio, 1)
    }

    // MARK: the routes asked

    func testTheLibraryIsAskedThroughTheViewAllRoutes() async throws {
        PhotosStub.say("/private/photos/lib/months", PhotosFixtures.months)
        PhotosStub.say("/private/photos/lib/month", PhotosFixtures.september)
        PhotosStub.say("/private/photos/lib/albums", PhotosFixtures.albums)
        PhotosStub.say("/private/photos/lib/item/" + id1, PhotosFixtures.info)
        let a = api()
        _ = try await a.months()
        _ = try await a.month("2026-09")
        _ = try await a.albums()
        _ = try await a.item(id1)
        let asked = PhotosStub.asked.map { ($0.path, Self.query($0)) }
        XCTAssertEqual(asked[0].0, "/private/photos/lib/months")
        XCTAssertEqual(asked[0].1, ["view": "all", "first": "1"])
        XCTAssertEqual(asked[1].1, ["view": "all", "month": "2026-09"])
        XCTAssertEqual(asked[2].0, "/private/photos/lib/albums")
        XCTAssertEqual(asked[3].0, "/private/photos/lib/item/" + id1)
    }

    func testAnAlbumIsAskedWithItsId() async throws {
        PhotosStub.say("/private/photos/lib/months", PhotosFixtures.months)
        _ = try await api().months(album: "66666666-6666-4666-8666-666666666666")
        let q = URLComponents(url: PhotosStub.asked[0], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(Set(q.map { "\($0.name)=\($0.value ?? "")" }), ["view=album", "album=66666666-6666-4666-8666-666666666666", "first=1"])
    }

    func testOnlyReadingRoutesAreAskedAndNeverTheOriginal() {
        XCTAssertEqual(PhotosAPI.filePath(id1, "thumbnail"), "private/photos/lib/file/\(id1)/thumbnail")
        XCTAssertEqual(PhotosAPI.filePath(id1, "preview"), "private/photos/lib/file/\(id1)/preview")
    }

    func testTheCookieGoesOnlyToTheAddressItBelongsTo() async throws {
        PhotosStub.say("/private/photos/lib/albums", PhotosFixtures.albums)
        let mine = HTTPCookie(properties: [.name: "s", .value: "invented", .domain: "aero.invalid", .path: "/"])!
        let other = HTTPCookie(properties: [.name: "t", .value: "elsewhere", .domain: "other.invalid", .path: "/"])!
        _ = try await api(cookies: [mine, other]).albums()
        XCTAssertEqual(PhotosStub.cookies.first ?? nil, "s=invented")
    }

    func testAPictureIsAskedWithItsVersionAndNoOtherQuery() async throws {
        PhotosStub.say("/private/photos/lib/file/\(id1)/thumbnail", "x")
        _ = try await api().picture(id1, "thumbnail", version: "f381c84a6ce4")
        XCTAssertEqual(PhotosStub.asked[0].query, "v=f381c84a6ce4")
        _ = try await api().picture(id1, "thumbnail", version: nil)
        XCTAssertNil(PhotosStub.asked[1].query)
    }

    // MARK: failures

    func testAFailureBecomesOneOfFiveStates() async {
        PhotosStub.say("/private/photos/lib/albums", #"{"error":"Locked","locked":true}"#, status: 401)
        await assertFails(.locked) { _ = try await self.api().albums() }
        PhotosStub.say("/private/photos/lib/albums", #"{"error":"Sign in"}"#, status: 401)
        await assertFails(.notSignedIn) { _ = try await self.api().albums() }
        PhotosStub.say("/private/photos/lib/albums", #"{"error":"Couldn't reach Fingus Core: down"}"#, status: 502)
        await assertFails(.server("Couldn't reach Fingus Core: down")) { _ = try await self.api().albums() }
        PhotosStub.say("/private/photos/lib/albums", "not json")
        await assertFails(.unreadable) { _ = try await self.api().albums() }
        await assertFails(.noAddress) { _ = try await self.api(address: nil).albums() }
    }

    func testAPCThatDoesNotAnswerIsUnreachableAndSaysWhyOnlyWhenAsked() async {
        PhotosStub.fail = true
        do { _ = try await api().albums(); XCTFail("should have thrown") } catch {
            guard case .unreachable(let why)? = error as? PhotosAPI.Failure else { return XCTFail("\(error)") }
            XCTAssertFalse(why.isEmpty)
            XCTAssertEqual(PhotosPhase.of(error), .failed(detail: why))
        }
    }

    func testEachFailureIsOneState() {
        XCTAssertEqual(PhotosPhase.of(PhotosAPI.Failure.locked), .locked)
        XCTAssertEqual(PhotosPhase.of(PhotosAPI.Failure.notSignedIn), .signedOut)
        XCTAssertEqual(PhotosPhase.of(PhotosAPI.Failure.server("nope")), .failed(detail: "nope"))
        XCTAssertEqual(PhotosPhase.of(PhotosAPI.Failure.noAddress), .failed(detail: "No PC address is set."))
    }

    private func assertFails(_ expected: PhotosAPI.Failure, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("should have thrown", file: file, line: line) } catch { XCTAssertEqual(error as? PhotosAPI.Failure, expected, file: file, line: line) }
    }

    // MARK: the models

    @MainActor
    func testTheLibraryOpensOnTheNewestMonthAndAsksForTheRestWhenItComesNear() async {
        PhotosStub.say("/private/photos/lib/months", PhotosFixtures.months)
        PhotosStub.say("/private/photos/lib/month", PhotosFixtures.september)
        let model = PhotosMonthsModel(api: api())
        XCTAssertEqual(model.phase, .loading)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.items["2026-10"]?.count, 4)
        XCTAssertNil(model.items["2026-09"])
        await model.loadMonth("2026-09")
        await model.loadMonth("2026-09")                         // already there: not asked again
        XCTAssertEqual(PhotosStub.asked.filter { $0.path.hasSuffix("/month") }.count, 1)
        XCTAssertEqual(model.flat.count, 5)
        XCTAssertEqual(model.flat.last?.id, "77777777-7777-4777-8777-777777777777")
    }

    @MainActor
    func testAMonthThatFailsOffersTryAgainAndTheRestStays() async {
        PhotosStub.say("/private/photos/lib/months", PhotosFixtures.months)
        let model = PhotosMonthsModel(api: api())
        await model.load()
        await model.loadMonth("2026-09")                         // 404: not answered
        XCTAssertTrue(model.failedMonths.contains("2026-09"))
        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.items["2026-10"]?.count, 4)
        PhotosStub.say("/private/photos/lib/month", PhotosFixtures.september)
        await model.retryMonth("2026-09")
        XCTAssertFalse(model.failedMonths.contains("2026-09"))
        XCTAssertEqual(model.items["2026-09"]?.count, 1)
    }

    @MainActor
    func testWithNoPCReachablePhotosSaysSoAndAskingAgainRecovers() async {
        PhotosStub.fail = true
        let model = PhotosMonthsModel(api: api())
        await model.load()
        guard case .failed = model.phase else { return XCTFail("\(model.phase)") }
        PhotosStub.fail = false
        PhotosStub.say("/private/photos/lib/months", PhotosFixtures.months)
        await model.load()
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor
    func testLockedStaysLockedAndNothingIsShown() async {
        PhotosStub.say("/private/photos/lib/albums", #"{"error":"Locked","locked":true}"#, status: 401)
        let model = PhotosAlbumsModel(api: api())
        await model.load()
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.albums, [])
    }

    @MainActor
    func testInfoIsAskedOnlyWhenItsSheetOpens() async {
        PhotosStub.say("/private/photos/lib/item/" + id1, PhotosFixtures.info)
        let model = PhotoInfoModel(api: api())
        XCTAssertTrue(PhotosStub.asked.isEmpty)
        await model.load(id1)
        XCTAssertEqual(model.info?.name, "IMG_0001.HEIC")
    }

    // MARK: the walk (the Lean names, as in PartRegistryTests; Swift checks on invented places, not the proofs)

    func testBackEnter() {
        var w = PhotosWalk()
        w.enter(.album(id: "a", name: "Trip"))
        let before = w
        w.enter(.photo(id: "p"))
        XCTAssertTrue(w.back())
        XCTAssertEqual(w, before)                                // Back undoes the step
    }

    func testTheHeaderIsTheWalk() {
        var w = PhotosWalk()
        XCTAssertEqual(w.crumbs, ["Home", "Photos", "Library"])
        w.switchTab(.albums)
        w.enter(.album(id: "a", name: "Trip"))
        w.enter(.photo(id: "p"))
        XCTAssertEqual(w.crumbs, ["Home", "Photos", "Albums", "Trip", "Photo"])
    }

    func testTapIsBacks() {
        var w = PhotosWalk()
        w.switchTab(.albums); w.enter(.album(id: "a", name: "Trip")); w.enter(.photo(id: "p"))
        for k in 1..<w.crumbs.count {
            var pressed = w
            while pressed.crumbs.count > max(k + 1, 3) { pressed.back() }     // Back until step k is the last (Photos is the tab she is on)
            XCTAssertEqual(w.tapped(k), pressed, "step \(k)")
        }
        XCTAssertNil(w.tapped(0))                                          // Home leaves the part
    }

    func testBackAtATabLeavesThePart() {
        var w = PhotosWalk()
        XCTAssertFalse(w.back())
        XCTAssertTrue(w.isAtTab)
    }

    func testATabIsASiblingNotAStep() {
        var w = PhotosWalk()
        w.enter(.albums)                                         // not a step
        XCTAssertEqual(w.places, [.library])
        w.switchTab(.albums)
        XCTAssertEqual(w.places, [.albums])
        w.enter(.album(id: "a", name: "Trip"))
        w.switchTab(.library)
        XCTAssertEqual(w.places, [.library])                      // the walk into the album was left with the tab
    }

    // MARK: words and dates

    func testDatesAndLengthsReadPlainly() {
        XCTAssertEqual(PhotosFormat.monthTitle("2026-10"), "October 2026")
        XCTAssertEqual(PhotosFormat.monthTitle("nonsense"), "nonsense")
        XCTAssertEqual(PhotosFormat.when("2026-10-05T12:03:09"), "5 October 2026, 12:03")
        XCTAssertEqual(PhotosFormat.when("2026-10-05"), "5 October 2026")
        XCTAssertEqual(PhotosFormat.length(12345), "0:12")
        XCTAssertEqual(PhotosFormat.length(3_723_000), "1:02:03")
        XCTAssertNil(PhotosFormat.length(nil))
        XCTAssertEqual(PhotosFormat.milliseconds("0:00:12.345000"), 12345)
        XCTAssertEqual(PhotosFormat.bytes(2345678), "2.3 MB")
    }

    func testATileIsSpokenWithItsKindAndDateNotItsName() {
        let item = PhotoItem(id: "x", taken: "2026-10-03T02:30:00", video: true, ms: 12345)
        XCTAssertEqual(PhotosTile.label(item), "Video, 0:12, 3 October 2026, 02:30")
    }

    // MARK: pictures, held in memory under a cap

    private func png() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.cgContext.setFillColor(UIColor.red.cgColor); $0.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
    }

    func testAPictureIsAskedOnceAndThenKeptInMemory() async {
        PhotosStub.answers["/private/photos/lib/file/\(id1)/thumbnail"] = (200, png())
        let images = PhotoImages(api: api())
        let first = await images.image(id1, "thumbnail", version: "v1")
        XCTAssertNotNil(first)
        let again = await images.image(id1, "thumbnail", version: "v1")
        XCTAssertNotNil(again)
        XCTAssertEqual(PhotosStub.asked.count, 1)
        _ = await images.image(id1, "thumbnail", version: "v2")                // another version is another picture
        XCTAssertEqual(PhotosStub.asked.count, 2)
    }

    func testAPictureThatCannotBeHadIsNilNotAnError() async {
        let images = PhotoImages(api: api())
        let got = await images.image(id1, "thumbnail", version: nil)           // 404 from the stub
        XCTAssertNil(got)
    }

    func testTheCacheHasACapAndCountsDecodedBytes() {
        XCTAssertEqual(PhotoImages.capBytes, 64 * 1024 * 1024)
        let image = UIImage(data: png())!
        XCTAssertEqual(PhotoImages.cost(image), Int(image.size.width * image.scale * image.size.height * image.scale) * 4)
    }

    // MARK: the part

    func testPhotosIsAPartThatNeedsThePCAndSaysSoWithoutOne() {
        let photos = PartCatalog.own.first { $0.id == "photos" }
        XCTAssertEqual(photos?.root, .photos)
        XCTAssertEqual(photos?.needs, .pcOnly)
        XCTAssertFalse(PartsSelection.offered(photos!, hasPC: false))          // the chooser says "Needs your PC"
        XCTAssertEqual(PartsSelection.tiles(added: ["organizer", "photos"], parts: PartCatalog.own, hasPC: false).map(\.id), ["organizer"])
        XCTAssertEqual(PartsSelection.tiles(added: ["organizer", "photos"], parts: PartCatalog.own, hasPC: true).map(\.id), ["organizer", "photos"])
    }

    func testAddingOrRemovingPhotosMovesNoOtherTile() {
        let before = ["organizer", "messages"]
        let added = PartsSelection.adding(before, "photos")
        XCTAssertEqual(Array(added.prefix(2)), before)
        XCTAssertEqual(PartsSelection.removing(added, "photos"), before)
        let g = Holarchy.home(tiles: before)
        XCTAssertTrue(g.addTile("photos").ok(["photos"]))
        XCTAssertTrue(g.addTile("photos").removeTile("photos").ok(["organizer"]))
        XCTAssertFalse(g.addTile("photos").removeTile("photos").ok(["photos"]))
    }
}
