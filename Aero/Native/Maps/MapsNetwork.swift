import Foundation
import MapLibre

// Where the Location part's requests may go: to the one server address the person gave the app, and nowhere else (standing rule 30 and Aryn's
// "nothing identifying to outside sites": no tile, symbol, letter or place-search request leaves the phone for any other host).
//
// Three layers, so one mistake is not enough to leak:
//  1. The style the map is given (`MapsStyle`) names only that server for its tiles, letters and symbols. A test reads every address in it.
//  2. Every session the part uses (its own data calls and the map's: MapLibre's sessions are built from `sessionConfiguration`) carries
//     `BlockOtherHostsProtocol`, which fails any request whose scheme, host and port are not the server's, before it is sent.
//  3. With no server address set, nothing is allowed at all: it fails closed.
// The map's disk cache of squares is turned off, so what she looked at is not kept on the phone (a test feature never lowers the privacy of
// data that already exists, standing rule 31).

/// The scheme, host and port a request must have to be allowed.
struct MapsOrigin: Equatable {
    var scheme: String
    var host: String
    var port: Int

    init?(_ url: URL?) {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : 0)
    }
}

enum MapsNetwork {
    private static let lock = NSLock()
    private static var allowedOrigin: MapsOrigin?
    private static var cookie: String?
    private static var blockedLog: [String] = []

    /// The server this part may talk to now, and the sign-in cookies the web view holds for it (a header value, or nil).
    static func use(base: URL?, cookieHeader: String?) {
        lock.lock(); defer { lock.unlock() }
        allowedOrigin = MapsOrigin(base)
        cookie = cookieHeader
        blockedLog = []
    }

    static var origin: MapsOrigin? { lock.lock(); defer { lock.unlock() }; return allowedOrigin }
    static var cookieHeader: String? { lock.lock(); defer { lock.unlock() }; return cookie }

    /// The hosts of the requests that were refused since `use`, for the tests (hosts only, never a path).
    static var blockedHosts: [String] { lock.lock(); defer { lock.unlock() }; return blockedLog }

    static func noteBlocked(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        blockedLog.append(url?.host ?? "none")
    }

    /// Whether `url` is the server (the same scheme, host and port).
    static func allows(_ url: URL?, origin: MapsOrigin?) -> Bool {
        guard let origin, let mine = MapsOrigin(url) else { return false }
        return mine == origin
    }

    /// The configuration for every session this part makes: nothing kept (no disk cache, no cookie storage), the sign-in cookie sent by hand to the
    /// server only, and the block in front of anything else. `extra` are further protocols (the tests' stand-in server).
    static func sessionConfiguration(extra: [AnyClass] = []) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.protocolClasses = [BlockOtherHostsProtocol.self] + extra + (config.protocolClasses ?? [])
        return config
    }

    private static var installed = false

    /// Once, before the first map is made: MapLibre's sessions are built from this configuration, its requests carry the cookie by the
    /// delegate below, and its disk cache of squares is turned off.
    static func installForMapLibre() {
        lock.lock()
        if installed { lock.unlock(); return }
        installed = true
        lock.unlock()
        MLNNetworkConfiguration.sharedManager.sessionConfiguration = sessionConfiguration()
        MLNNetworkConfiguration.sharedManager.delegate = MapsRequestDelegate.shared
        MLNOfflineStorage.shared.setMaximumAmbientCacheSize(0) { _ in }
    }
}

/// Fails any request that is not for the server before it leaves the phone. Only claims the requests it refuses, so the server's own go on to the
/// ordinary network stack.
final class BlockOtherHostsProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        !MapsNetwork.allows(request.url, origin: MapsNetwork.origin)
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        MapsNetwork.noteBlocked(request.url)
        client?.urlProtocol(self, didFailWithError: NSError(domain: "FingusMaps", code: 1,
                            userInfo: [NSLocalizedDescriptionKey: "The map only asks your PC."]))
    }
    override func stopLoading() {}
}

/// MapLibre calls this on its own threads before each request: the sign-in cookie goes to the server and to no one else.
final class MapsRequestDelegate: NSObject, MLNNetworkConfigurationDelegate {
    static let shared = MapsRequestDelegate()

    @objc(willSendRequest:)
    func willSend(_ request: NSMutableURLRequest) -> NSMutableURLRequest {
        if MapsNetwork.allows(request.url, origin: MapsNetwork.origin), let header = MapsNetwork.cookieHeader {
            request.setValue(header, forHTTPHeaderField: "Cookie")
        }
        return request
    }
}
