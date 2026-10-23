import Foundation
import XCTest

/// A stand-in for Aero's server on the PC, in the app's own process: a request to any address is answered from a table, with the JSON the
/// server's code made (tools/live_shapes.py, run over invented data, into Fixtures/live). Nothing goes to a network, so a test of how the
/// app reads Aero's answers needs neither a Mac with a PC beside it nor a hand-written guess of a shape.
final class LiveStub: URLProtocol {
    struct Answer {
        var status: Int
        var body: Data
        var type = "application/json"
        /// A transport failure instead of an answer (no connection, timed out).
        var failure: URLError.Code?
    }

    private static let lock = NSLock()
    private static var routes: [String: (URLRequest) -> Answer] = [:]
    private static var requests: [String] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        routes = [:]
        requests = []
    }

    /// `route("POST /private/org") { _ in ... }`: the method and the path after the address.
    static func route(_ key: String, _ handler: @escaping (URLRequest) -> Answer) {
        lock.lock(); defer { lock.unlock() }
        routes[key] = handler
    }

    static func json(_ key: String, status: Int = 200, _ text: String) {
        route(key) { _ in Answer(status: status, body: Data(text.utf8)) }
    }

    static var seen: [String] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LiveStub.self]
        config.httpShouldSetCookies = false
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// A file made by tools/live_shapes.py.
    static func fixture(_ name: String, in bundle: Bundle) throws -> Data {
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/live"), "\(name) is not in the test bundle")
        return try Data(contentsOf: url)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = "\(request.httpMethod ?? "GET") \(url.path)"
        LiveStub.lock.lock()
        LiveStub.requests.append(key)
        let handler = LiveStub.routes[key]
        LiveStub.lock.unlock()
        let answer = handler?(request) ?? Answer(status: 404, body: Data("404: Not Found".utf8), type: "text/plain; charset=utf-8")
        if let code = answer.failure {
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": answer.type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: answer.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
