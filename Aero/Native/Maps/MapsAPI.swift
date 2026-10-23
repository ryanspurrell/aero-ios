import Foundation
import WebKit

/// Reads the Location screen's data from Aero's server the way the page does, with the web view's sign-in cookie sent by hand (as `ChatAPI`
/// does). Only reads: three GET routes, all the page already uses. The server decides who may see them: they answer only over the tailnet and
/// only to the owner.
///
///   GET private/location                      now, today, her places, settings
///   GET private/location/day?day=YYYY-MM-DD   one day: its visits, trips and path
///   GET private/location/map/info.json        whether the PC is getting the map, whether the VPN route is down
///
/// Reuse: `ChatAPI.url` and `ChatAPI.applicable` build the address and pick the cookies (the same rules); the session's block on other hosts is
/// `MapsNetwork`.
final class MapsAPI {
    enum Failure: Error, Equatable {
        case noAddress
        /// The server answers this only through the tailnet.
        case needsTailnet
        case notSignedIn
        /// The PC did not answer.
        case unreachable
        case unreadable
        case server(String)

        /// What the screen says.
        var words: String {
            switch self {
            case .noAddress: return MapsText.needsPC
            case .needsTailnet: return "Location only shows through your tailnet"
            case .notSignedIn: return "Open Aero once to sign in"
            case .unreachable: return "Your PC didn't answer"
            case .unreadable: return "That didn't read. Try again."
            case .server(let said): return said
            }
        }
    }

    private let session: URLSession
    private let base: () -> URL?
    private let cookies: (URL) async -> [HTTPCookie]
    private let decoder = JSONDecoder()

    init(session: URLSession? = nil,
         base: @escaping () -> URL? = { AppInfo.address },
         cookies: @escaping (URL) async -> [HTTPCookie] = MapsAPI.webViewCookies) {
        self.session = session ?? URLSession(configuration: MapsNetwork.sessionConfiguration())
        self.base = base
        self.cookies = cookies
    }

    /// The sign-in cookies the web view holds (read on the main thread, as WebKit asks).
    static func webViewCookies(_ url: URL) async -> [HTTPCookie] {
        await withCheckedContinuation { done in
            DispatchQueue.main.async { WKWebsiteDataStore.default().httpCookieStore.getAllCookies { done.resume(returning: $0) } }
        }
    }

    /// Tells the network layer which server this is and what cookie header it gets, then builds the request. Read once, so a request is never
    /// sent to one address with another's cookie.
    private func prepared(_ path: String, _ query: [String: String]) async throws -> URLRequest {
        guard let server = base(), let url = ChatAPI.url(base: server, path: path, query: query) else { throw Failure.noAddress }
        let mine = ChatAPI.applicable(await cookies(url), to: url)
        guard base() == server else { throw Failure.noAddress }
        let header = HTTPCookie.requestHeaderFields(with: mine)["Cookie"]
        MapsNetwork.use(base: server, cookieHeader: header)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let header { request.setValue(header, forHTTPHeaderField: "Cookie") }
        return request
    }

    static func failure(status: Int, data: Data) -> Failure? {
        struct Said: Decodable { var error: String?; var open: String? }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if status == 403, said?.open != nil { return .needsTailnet }
        if status == 401 || status == 403 { return .notSignedIn }
        if status >= 400 { return .server(said?.error ?? "That didn't work. Try again.") }
        return nil
    }

    private func get<Answer: Decodable>(_ path: String, _ query: [String: String] = [:], as type: Answer.Type) async throws -> Answer {
        let request = try await prepared(path, query)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw Failure.unreachable }
        if let http = response as? HTTPURLResponse, let bad = MapsAPI.failure(status: http.statusCode, data: data) { throw bad }
        do { return try decoder.decode(Answer.self, from: data) } catch { throw Failure.unreadable }
    }

    func overview() async throws -> MapsOverview { try await get("private/location", as: MapsOverview.self) }
    func day(_ key: String) async throws -> MapsDay { try await get("private/location/day", ["day": key], as: MapsDay.self) }
    func info() async throws -> MapsInfo { try await get("private/location/map/info.json", as: MapsInfo.self) }
}
