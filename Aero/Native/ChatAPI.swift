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
///   POST devices                          this phone as a device {device, ecdh, sign, label}; answers {ok, trusted, name}: a new device waits for a
///                                         device she already uses to approve it (name is its own fruit name); an older Aero answers {ok} and
///                                         refused with {"error", "devices_full": n} at the most, or {"device_removed": true} for a device she removed
///   GET  devices/mine.json                her devices for chats: {now, devices: [{device, name, kind, added, trusted, approved_by, ecdh, sign}]} (this phone's own trust)
///   POST devices/approve                  {by, device, ts, proof, code}: `by` (a trusted device) signed "approve|<person>|<device>|<ecdh>|<sign>|<ts>|<code>"
///   POST devices/remove                   {by, device, ts, proof}: a chat key forgotten, signed "remove|<person>|<device>|<ts>"
///   GET  one-devices.json?chat=<id>       her devices, one row each with its sign-ins, chat keys and file key inside, and the pairs that may be one
///   POST one-devices/rename               {thing, name}: a label for the whole device
///   POST one-devices/merge                {a, b}: b's parts join a, after her confirmation
///   POST one-devices/remove               {thing, ack?}: the device and all its parts go, step by step; 409 {confirm: {reasons, info}} until `ack` (that info) is sent
///   POST rooms/<id>/ai                    {name, fields: {model}}: switch an AI member's model
///   POST rooms/<id>/name                  {name}: a person's name for the chat (the PC then leaves it as it is)
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
        /// Aero says this device was removed from the person's list and must make new keys to be added again.
        case deviceRemoved
        case server(String)
        case unreadable
        /// A 5xx that is not Aero's word (Cloudflare's or the tunnel's, with nothing behind it): the way to Aero said nothing.
        case notAero(Int)
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
            var error: String?; var locked: Bool?; var devicesFull: Int?; var deviceRemoved: Bool?
            enum CodingKeys: String, CodingKey { case error, locked; case devicesFull = "devices_full"; case deviceRemoved = "device_removed" }
        }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if said?.locked == true { return .locked }
        if status >= 400, let full = said?.devicesFull { return .devicesFull(full) }
        // the installed Aero refuses a ninth device with the store's own sentence and no `devices_full` (that field is on branch chat-devices
        // only); the count is not said then
        if status >= 400, ChatAPI.saysTooManyDevices(said?.error) { return .devicesFull(0) }
        if status >= 400, said?.deviceRemoved == true { return .deviceRemoved }
        if status == 401 || status == 403 { return .notSignedIn }
        if status >= 400, said?.error == nil, StopWords.isEdge(status) { return .notAero(status) }
        if status >= 400 { return .server(said?.error ?? "That didn't work. Try again.") }
        return nil
    }

    /// The store's sentence for the most devices a person may have (fingus_messages_store.register_device).
    static func saysTooManyDevices(_ words: String?) -> Bool {
        words?.lowercased().hasPrefix("too many devices") == true
    }

    private func run(_ request: URLRequest, acceptConfirm: Bool = false) async throws -> Data {
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request) }
        catch {
            await ConnectionMonitor.shared.sawOwn(.refused, backend: .pc)
            throw error
        }
        let (data, response) = result
        if let http = response as? HTTPURLResponse {
            // any answer below 500 is Aero's, a refusal included (as Doctor's own check "your PC answers" reads it)
            await ConnectionMonitor.shared.sawOwn(http.statusCode < 500 ? .reached : .refused, backend: .pc)
            if let failure = ChatAPI.failure(status: http.statusCode, data: data) {
                // a removal that needs her confirmation is an answer, not a failure: it carries what she is to be shown
                if acceptConfirm, http.statusCode == 409, case .confirm? = OneRemoveResult.read(data) { return data }
                throw failure
            }
        }
        return data
    }

    private func get<Answer: Decodable>(_ path: String, _ query: [String: String] = [:], as type: Answer.Type) async throws -> Answer {
        var request = try await prepared(path, query)
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let data = try await run(request)
        do { return try decoder.decode(Answer.self, from: data) } catch { throw Failure.unreadable }
    }

    private func post<Body: Encodable>(_ path: String, _ body: Body, acceptConfirm: Bool = false) async throws -> Data {
        var request = try await prepared(path, [:])
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return try await run(request, acceptConfirm: acceptConfirm)
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

    @discardableResult
    func register(device: ChatDevice, label: String) async throws -> ChatRegistration {
        struct Body: Encodable { var device: String; var ecdh: String; var sign: String; var label: String }
        let data = try await post("devices", Body(device: device.id, ecdh: device.ecdhPublic, sign: device.signPublic, label: label))
        return ChatRegistration.read(data)
    }

    // MARK: this person's chat devices

    func devicesMine() async throws -> DevicesAnswer {
        try await get("devices/mine.json", as: DevicesAnswer.self)
    }

    /// Her devices as one list: one row per device with its parts inside. `chat` is this phone's own chat key, so the row it is in is "this".
    func oneDevices(chat: String?) async throws -> OneDevicesAnswer {
        try await get("one-devices.json", chat.map { ["chat": $0] } ?? [:], as: OneDevicesAnswer.self)
    }

    /// The whole device's name after the change (a label only).
    func oneRename(_ thing: String, to name: String) async throws -> String {
        struct Body: Encodable { var thing: String; var name: String }
        struct Done: Decodable { var name: String? }
        let data = try await post("one-devices/rename", Body(thing: thing, name: name))
        return ((try? decoder.decode(Done.self, from: data))?.name) ?? name
    }

    /// `gone`'s parts join `keep`, which keeps its name. Only after she has confirmed, seeing the evidence.
    func oneMerge(keep: String, gone: String) async throws {
        struct Body: Encodable { var a: String; var b: String }
        _ = try await post("one-devices/merge", Body(a: keep, b: gone))
    }

    /// Remove a device and every part of it, or carry on a removal that stopped. A device used lately, or never matched to one she uses, is
    /// not removed in one step: the answer is `.confirm`, and she sends the same evidence back as `ack` when she confirms.
    func oneRemove(_ thing: String, ack: OneInfo? = nil) async throws -> OneRemoveResult {
        struct Body: Encodable { var thing: String; var ack: OneInfo? }
        let data = try await post("one-devices/remove", Body(thing: thing, ack: ack), acceptConfirm: true)
        guard let got = OneRemoveResult.read(data) else { throw Failure.unreadable }
        return got
    }

    struct Signed: Encodable {
        var by: String
        var device: String
        var ts: Int
        var proof: String
        /// The code of the waiting device's keys that she saw on both screens (approve only; Aero checks it is those keys').
        var code: String? = nil
    }

    func approveDevice(_ body: Signed) async throws {
        _ = try await post("devices/approve", body)
    }

    /// Take a device out of the list, signed by a device already trusted. Aero says "That device isn't in your list." for one that is gone,
    /// which is what was asked for.
    func removeDeviceSigned(_ body: Signed) async throws {
        do { _ = try await post("devices/remove", body) }
        catch let f as Failure where ChatAPI.alreadyGone(f) { return }
    }

    /// Its name after the change (Aero trims it and refuses a name another device has).
    func renameDevice(_ device: String, to name: String) async throws -> String {
        struct Body: Encodable { var device: String; var name: String }
        struct Done: Decodable { var name: String? }
        let data = try await post("devices/rename", Body(device: device, name: name))
        return ((try? decoder.decode(Done.self, from: data))?.name) ?? name
    }

    // MARK: one chat's settings

    /// Switch the model of one AI member of a chat. Aero refuses a model this person could not add themselves.
    func setModel(room: String, member: String, model: String) async throws {
        struct Fields: Encodable { var model: String }
        struct Body: Encodable { var name: String; var fields: Fields }
        _ = try await post("rooms/\(room)/ai", Body(name: member, fields: Fields(model: model)))
    }

    /// A person's name for the chat. An empty name clears it and the PC names the chat again.
    func renameRoom(_ room: String, to name: String) async throws {
        struct Body: Encodable { var name: String }
        _ = try await post("rooms/\(room)/name", Body(name: name))
    }

    /// What Aero says to a device that is not in the person's list: it is already gone, which is what was asked for.
    static let notInList = "That device isn't in your list."

    static func alreadyGone(_ failure: Failure) -> Bool {
        if case .server(let words) = failure { return words == notInList }
        return false
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
