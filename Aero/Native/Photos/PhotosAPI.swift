import Foundation
import UIKit
import WebKit

/// Asks Aero's server for Photos the way the page does, read-only. The routes are the ones the page already uses (aero_web.py
/// `private_photo_lib_*`, which pass Core's library answers on); the server decides what this person may see, Locked and covered photos
/// included, and says so with a 401 `{"error":"Locked","locked":true}` (`face_locked`). Immich is still the source behind them
/// (projects/core/design__photos_native_migration_2026-10-22.md: no native backend is active), and the app does not know that: it asks
/// Aero, so the day the backend changes, nothing here does.
///
/// Routes, all under the address the app was given (no query that the page does not send):
///   GET  private/photos/lib/months?view=all|album&album=<id>&first=1   the months, newest first, with the newest month's items when first=1
///   GET  private/photos/lib/month?view=&album=&month=YYYY-MM           one month's items
///   GET  private/photos/lib/item/<id>                                  one photo's info
///   GET  private/photos/lib/albums                                     the albums
///   GET  private/photos/lib/file/<id>/thumbnail|preview[?v=<version>]  a picture (the original is not asked for)
/// The sign-in cookie is the web view's, copied into each request's own header, as Chat does; nothing is stored.
final class PhotosAPI {
    enum Failure: Error, Equatable {
        case noAddress, notSignedIn, locked
        /// The PC did not answer (offline, asleep, the address is wrong): the system's words.
        case unreachable(String)
        /// Aero answered with an error: its words.
        case server(String)
        case unreadable
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let address: () -> URL?
    private let cookies: () async -> [HTTPCookie]

    /// An ephemeral session of its own: no cache on disk and no cookie storage (each request carries its own).
    static func isolatedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    /// `session`, `address` and `cookies` are given by tests; the app uses the saved address and the web view's cookies.
    init(session: URLSession? = nil, address: @escaping () -> URL? = { AppInfo.address },
         cookies: @escaping () async -> [HTTPCookie] = { await PhotosAPI.webViewCookies() }) {
        self.session = session ?? PhotosAPI.isolatedSession()
        self.address = address
        self.cookies = cookies
    }

    @MainActor
    static func webViewCookies() async -> [HTTPCookie] { await WKWebsiteDataStore.default().httpCookieStore.allCookies() }

    /// What the server said when it refused: Locked, a sign-in problem, or its own words.
    static func failure(status: Int, data: Data) -> Failure? {
        struct Said: Decodable { var error: String?; var locked: Bool? }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if said?.locked == true { return .locked }
        if status == 401 || status == 403 { return .notSignedIn }
        if status >= 400 { return .server(said?.error ?? "That didn't work.") }
        return nil
    }

    @MainActor
    private func prepared(_ path: String, _ query: [String: String]) async throws -> URLRequest {
        guard let base = address(), let url = ChatAPI.url(base: base, path: path, query: query) else { throw Failure.noAddress }
        let own = ChatAPI.applicable(await cookies(), to: url)
        guard address() == base else { throw Failure.noAddress }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (field, value) in HTTPCookie.requestHeaderFields(with: own) { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    private func fetch(_ path: String, _ query: [String: String] = [:]) async throws -> Data {
        let request = try await prepared(path, query)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.unreachable(error.localizedDescription) }
        if let http = response as? HTTPURLResponse, let failure = PhotosAPI.failure(status: http.statusCode, data: data) { throw failure }
        return data
    }

    private func get<Answer: Decodable>(_ path: String, _ query: [String: String] = [:], as type: Answer.Type) async throws -> Answer {
        let data = try await fetch(path, query)
        do { return try decoder.decode(Answer.self, from: data) } catch { throw Failure.unreadable }
    }

    // MARK: reading

    /// `album`: nil for the library, an album's id for its months.
    func months(album: String? = nil) async throws -> PhotoMonthsAnswer {
        try await get("private/photos/lib/months", PhotosAPI.source(album, ["first": "1"]), as: PhotoMonthsAnswer.self)
    }

    func month(_ month: String, album: String? = nil) async throws -> PhotoMonthAnswer {
        try await get("private/photos/lib/month", PhotosAPI.source(album, ["month": month]), as: PhotoMonthAnswer.self)
    }

    func item(_ id: String) async throws -> PhotoInfo {
        try await get("private/photos/lib/item/" + id, as: PhotoInfo.self)
    }

    func albums() async throws -> [PhotoAlbum] {
        try await get("private/photos/lib/albums", as: PhotoAlbumsAnswer.self).albums
    }

    /// The query for the library (`view=all`) or for one album.
    static func source(_ album: String?, _ more: [String: String]) -> [String: String] {
        var q = more
        if let album { q["view"] = "album"; q["album"] = album } else { q["view"] = "all" }
        return q
    }

    /// A picture's path under the address: `what` is "thumbnail" or "preview" (never the original: nothing big is fetched to be looked at).
    static func filePath(_ id: String, _ what: String) -> String { "private/photos/lib/file/\(id)/\(what)" }

    func picture(_ id: String, _ what: String, version: String?) async throws -> Data {
        try await fetch(PhotosAPI.filePath(id, what), version.map { ["v": $0] } ?? [:])
    }
}

/// Pictures for the screen, held in memory only: the cache is size-capped and gone when the app is closed or memory is short (NSCache drops its
/// entries then). Nothing is written to the phone's storage.
final class PhotoImages {
    /// Bytes of decoded pictures to keep. Picked, not grounded: about 14 full-width 1170 x 1170 pictures, or hundreds of grid thumbnails; hers to change.
    static let capBytes = 64 * 1024 * 1024

    private let api: PhotosAPI
    private let cache = NSCache<NSString, UIImage>()

    init(api: PhotosAPI) {
        self.api = api
        cache.totalCostLimit = PhotoImages.capBytes
    }

    static func key(_ id: String, _ what: String, _ version: String?) -> String { "\(id)|\(what)|\(version ?? "")" }

    /// Bytes a decoded picture takes in memory (width x height x 4).
    static func cost(_ image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale) * 4
    }

    func cached(_ id: String, _ what: String, version: String?) -> UIImage? {
        cache.object(forKey: PhotoImages.key(id, what, version) as NSString)
    }

    /// The picture, from the cache or the PC; nil when it cannot be had (the tile then shows its plain cover).
    func image(_ id: String, _ what: String, version: String?) async -> UIImage? {
        if let hit = cached(id, what, version: version) { return hit }
        guard let data = try? await api.picture(id, what, version: version), let image = UIImage(data: data) else { return nil }
        cache.setObject(image, forKey: PhotoImages.key(id, what, version) as NSString, cost: PhotoImages.cost(image))
        return image
    }

    func forgetAll() { cache.removeAllObjects() }
}
