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
///   POST devices                          this phone as a device {device, ecdh, sign, label}
///   POST rooms/new                        a new chat {device, room, name, members, seals, private}
///   POST rooms/<id>/send                  a sealed message {device, epoch, mentions, iv, ct, sig}
///   POST rooms/<id>/read                  read up to {seq}
///   POST rooms/<id>/stop                  stop the reply being written
///   GET  private/unlock/status?peek=1     whether Locked is open for this browser (asking does not keep it open)
final class ChatAPI {
    enum Failure: Error, Equatable {
        case noAddress, notSignedIn, locked
        case server(String)
        case unreadable
    }

    private let session: URLSession
    private let decoder = JSONDecoder()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// The address plus a path and query. The path is relative to the address the app was given, as the page's `%(path)s` is.
    static func url(base: URL, path: String, query: [String: String] = [:]) -> URL? {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        var parts = URLComponents(string: text + "/" + path)
        if !query.isEmpty { parts?.queryItems = query.sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts?.url
    }

    private func endpoint(_ path: String, _ query: [String: String] = [:]) throws -> URL {
        guard let base = AppInfo.address else { throw Failure.noAddress }
        guard let url = ChatAPI.url(base: base, path: path, query: query) else { throw Failure.noAddress }
        return url
    }

    @MainActor
    private func shareCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    /// What the server said when it refused: the Locked answer, a sign-in problem, or its own words.
    static func failure(status: Int, data: Data) -> Failure? {
        struct Said: Decodable { var error: String?; var locked: Bool? }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if said?.locked == true { return .locked }
        if status == 401 || status == 403 { return .notSignedIn }
        if status >= 400 { return .server(said?.error ?? "That didn't work. Try again.") }
        return nil
    }

    private func run(_ request: URLRequest) async throws -> Data {
        await shareCookies()
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let failure = ChatAPI.failure(status: http.statusCode, data: data) { throw failure }
        return data
    }

    private func get<Answer: Decodable>(_ path: String, _ query: [String: String] = [:], as type: Answer.Type) async throws -> Answer {
        var request = URLRequest(url: try endpoint(path, query))
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data = try await run(request)
        do { return try decoder.decode(Answer.self, from: data) } catch { throw Failure.unreadable }
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body) async throws -> Data {
        var request = URLRequest(url: try endpoint(path))
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
