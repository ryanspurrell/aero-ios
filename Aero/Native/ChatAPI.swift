import Foundation
import WebKit

/// Asks Aero's server for chats the way the page does, with the web view's sign-in cookie copied into URLSession's storage before a call
/// (the same way as `OrganizerAPI`). Only routes the page already uses are called; the server decides what this person may see, Locked
/// included, and says so with a 401 `{"error":"Locked","locked":true}` (aero_web.py `face_locked`).
///
/// Routes (all under the address the app was given):
///   GET  rooms.json                       the chats, and who this is
///   GET  rooms/<id>.json?device=&after=   one chat: members, sealed messages after `after`, the keys sealed to this device, replies being written
///   GET  rooms/<id>/busy                  whether a reply is being written now
///   GET  rooms/people.json                the models a new chat may use
///   GET  devices.json?people=a,b          public keys of devices, to seal a new chat's key to
///   POST devices                          this phone as a device {device, ecdh, sign, label}; refused with {"error", "devices_full": n} at the most
///   POST devices/remove                   one of this person's own devices {device}, taken out of their list
///   POST rooms/new                        a new chat {device, room, name, members, seals, private}
///   POST rooms/<id>/send                  a sealed message {device, epoch, mentions, iv, ct, sig}
///   POST rooms/<id>/read                  read up to {seq}
///   POST rooms/<id>/stop                  stop the reply being written
///   GET  private/unlock/status?peek=1     whether Locked is open for this browser (asking does not keep it open)
final class ChatAPI {
    enum Failure: Error, Equatable {
        case noAddress, notSignedIn, locked
        /// Aero refused this phone as a chat device because the person already has the most (Messages keeps eight): how many they have
        /// (0 when it was not said). Their own list is in Aero's Devices page, where one can be removed.
        case devicesFull(Int)
        case server(String)
        case unreadable
    }

    private let session: URLSession
    private let decoder = JSONDecoder()

    /// An ephemeral session of its own: no cache on disk (what comes back is ciphertext, live reply text and the list of chats), and cookies
    /// kept apart from the rest of the app, holding only the web view's cookies that apply to this address.
    static func isolatedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // cookies are never taken from or put into a storage: each request carries the ones chosen for it (`prepared`)
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config)
    }

    init(session: URLSession? = nil) {
        self.session = session ?? ChatAPI.isolatedSession()
    }

    /// Nothing is kept between requests (see `prepared`), so there is nothing to drop; kept so that a reset reads the same everywhere.
    func forgetCookies() {}

    /// The cookies of a set that a request to `url` would carry: same host (or a parent domain of it), a path that covers it, and secure ones
    /// only over https.
    static func applicable(_ cookies: [HTTPCookie], to url: URL) -> [HTTPCookie] {
        guard let host = url.host?.lowercased() else { return [] }
        return cookies.filter { c in
            let domain = String(c.domain.lowercased().drop(while: { $0 == "." }))
            let hostOK = host == domain || host.hasSuffix("." + domain)
            let path = url.path.isEmpty ? "/" : url.path
            let pathOK = c.path == "/" || path == c.path || path.hasPrefix(c.path.hasSuffix("/") ? c.path : c.path + "/")
            let secureOK = !c.isSecure || url.scheme == "https"
            return hostOK && pathOK && secureOK
        }
    }

    /// The address plus a path and query. The path is relative to the address the app was given, as the page's `%(path)s` is.
    static func url(base: URL, path: String, query: [String: String] = [:]) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        var parts = URLComponents(string: text + "/" + path)
        if !query.isEmpty { parts?.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts?.url
    }

    /// One request bound, at the start of the call, to one address and the web view's cookies that apply to it: the address is read once, the
    /// cookies are read from the web view right then and sent in this request's own header, and if the address changed while they were read
    /// the call stops, so a request can never go to one address with another's cookies.
    @MainActor
    private func prepared(_ path: String, _ query: [String: String]) async throws -> URLRequest {
        guard let base = AppInfo.address, let url = ChatAPI.url(base: base, path: path, query: query) else { throw Failure.noAddress }
        let cookies = ChatAPI.applicable(await WKWebsiteDataStore.default().httpCookieStore.allCookies(), to: url)
        guard AppInfo.address == base else { throw Failure.noAddress }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }

    /// What the server said when it refused: the Locked answer, a sign-in problem, or its own words.
    static func failure(status: Int, data: Data) -> Failure? {
        struct Said: Decodable {
            var error: String?; var locked: Bool?; var devicesFull: Int?
            enum CodingKeys: String, CodingKey { case error, locked; case devicesFull = "devices_full" }
        }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if said?.locked == true { return .locked }
        if status >= 400, let full = said?.devicesFull { return .devicesFull(full) }
        if status == 401 || status == 403 { return .notSignedIn }
        if status >= 400 { return .server(said?.error ?? "That didn't work. Try again.") }
        return nil
    }

    private func run(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let failure = ChatAPI.failure(status: http.statusCode, data: data) { throw failure }
        return data
    }

    private func get<Answer: Decodable>(_ path: String, _ query: [String: String] = [:], as type: Answer.Type) async throws -> Answer {
        var request = try await prepared(path, query)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data = try await run(request)
        do { return try decoder.decode(Answer.self, from: data) } catch { throw Failure.unreadable }
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Data {
        var request = try await prepared(path, [:])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await run(request)
    }

    // MARK: reading

    func rooms() async throws -> ChatRoomsAnswer {
        try await get("rooms.json", as: ChatRoomsAnswer.self)
    }

    func room(_ id: String, device: String, after: Int) async throws -> ChatRoomAnswer {
        try await get("rooms/\(id).json", ["device": device, "after": String(after)], as: ChatRoomAnswer.self)
    }

    func busy(_ id: String) async throws -> Bool {
        struct Busy: Decodable { var busy: Bool }
        return try await get("rooms/\(id)/busy", as: Busy.self).busy
    }

    func models() async throws -> [String] {
        struct People: Decodable { var models: [String]? }
        return try await get("rooms/people.json", as: People.self).models ?? []
    }

    func devices(of people: [String]) async throws -> [String: [ChatDeviceInfo]] {
        struct Answer: Decodable { var devices: [String: [ChatDeviceInfo]] }
        return try await get("devices.json", ["people": people.joined(separator: ",")], as: Answer.self).devices
    }

    /// Whether Locked is open for this browser. `peek` so that asking does not keep it open.
    func lockedIsOpen() async throws -> Bool {
        struct Status: Decodable { var unlocked: Bool?; var here: Bool? }
        let s = try await get("private/unlock/status", ["peek": "1"], as: Status.self)
        return s.unlocked ?? false
    }

    // MARK: writing

    func register(device: ChatDevice, label: String) async throws {
        struct Body: Encodable { var device: String; var ecdh: String; var sign: String; var label: String }
        _ = try await post("devices", Body(device: device.id, ecdh: device.ecdhPublic, sign: device.signPublic, label: label))
    }

    /// Take one of this person's own devices out of their list in Aero (the entry a renewal put away). Never another person's: Aero answers
    /// 404 for an id that is not in the signed-in person's list.
    func removeDevice(_ id: String) async throws {
        struct Body: Encodable { var device: String }
        _ = try await post("devices/remove", Body(device: id))
    }

    struct NewRoom: Encodable {
        struct Member: Encodable { var kind: String; var name: String; var model: String }
        var device: String
        var room: String
        var name: String
        var members: [Member]
        var seals: [ChatSealOut]
        var `private`: Bool
    }

    func newRoom(_ body: NewRoom) async throws {
        _ = try await post("rooms/new", body)
    }

    struct Send: Encodable {
        var device: String
        var epoch: Int
        var mentions: [String]
        var iv: String
        var ct: String
        var sig: String
    }

    /// The message's number in the chat (`seq`), which a reply is later known to follow.
    func send(_ room: String, _ body: Send) async throws -> Int {
        struct Sent: Decodable { var seq: Int? }
        let data = try await post("rooms/\(room)/send", body)
        return (try? decoder.decode(Sent.self, from: data))?.seq ?? 0
    }

    func read(_ room: String, upTo seq: Int) async {
        struct Body: Encodable { var seq: Int }
        _ = try? await post("rooms/\(room)/read", Body(seq: seq))
    }

    func stop(_ room: String) async throws {
        struct Empty: Encodable {}
        _ = try await post("rooms/\(room)/stop", Empty())
    }
}
