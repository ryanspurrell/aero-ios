import Foundation
import WebKit

/// Asks Organizer, through Aero's own server, the way the page does: `POST <address>/private/org {name, args}`
/// (aero_web.py `private_org`). The sign-in is the web view's own cookie, copied into URLSession's storage before a call, so the app
/// asks as the same person and Aero's server decides what it may see (Locked mode included: the server says which mode this is, never
/// the app).
///
/// The page's path prefix is the address the app was given (the same address the web view shows), so the endpoint is that address
/// plus "private/org".
final class OrganizerAPI: OrganizerBackend {
    var kind: BackendKind { .pc }

    enum Failure: LocalizedError {
        case noAddress, notSignedIn, server(String)
        var errorDescription: String? {
            switch self {
            case .noAddress: return "No address is set."
            case .notSignedIn: return "Sign in first."
            case .server(let words): return words
            }
        }
    }

    private let session: URLSession
    private let decoder = OrganizerDecoder.make()

    init(session: URLSession = .shared) {
        self.session = session
    }

    private func endpoint(_ path: String) throws -> URL {
        guard let base = AppInfo.address else { throw Failure.noAddress }
        return base.appendingPathComponent(path)
    }

    /// The web view's cookies for this server, handed to URLSession.
    @MainActor
    private func shareCookies() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        for cookie in cookies { HTTPCookieStorage.shared.setCookie(cookie) }
    }

    /// One Organizer operation; the decoded answer.
    func call<Answer: Decodable>(_ name: String, _ args: [String: JSONValue] = [:], as type: Answer.Type) async throws -> Answer {
        await shareCookies()
        var request = URLRequest(url: try endpoint("private/org"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["name": JSONValue.string(name), "args": JSONValue.object(args)])
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 { throw Failure.notSignedIn }
        if let said = try? decoder.decode(ErrorAnswer.self, from: data), let words = said.error { throw Failure.server(words) }
        return try decoder.decode(Answer.self, from: data)
    }

    /// A change that answers with nothing the app needs (a question's choice, Done).
    func send(_ name: String, _ args: [String: JSONValue] = [:]) async throws {
        _ = try await call(name, args, as: Ignored.self)
    }

    func calendar(span: CalendarSpan, date: String) async throws -> CalendarAnswer {
        try await call("calendar", ["span": .string(span.rawValue), "date": .string(date)], as: CalendarAnswer.self)
    }

    /// On the PC the line is read there; a question it was not sure of waits on the item and is asked in the day, so none comes back here.
    func quickAdd(_ text: String) async throws -> QuickAddOutcome {
        try await send("quickadd", ["text": .string(text)])
        return QuickAddOutcome(title: text, typed: text, question: nil, likeliest: nil)
    }

    func keepPlain(_ question: Question) async throws {
        try await send("update", ["id": .string(question.id), "attention": .string("now")])
    }

    func apply(_ change: Change) async throws {
        try await send(change.name, change.args)
    }

    /// Whether anyone was let help this person with their reminders: the page's "Ask for help" shows only then
    /// (`GET <address>/helping/given`, Core's answer through Aero).
    func helperNames() async -> [String] {
        await shareCookies()
        guard let url = try? endpoint("helping/given"),
              let (data, _) = try? await session.data(from: url),
              let given = try? decoder.decode(Given.self, from: data) else { return [] }
        return given.given.filter { $0.kinds.contains("unsure") }.map(\.name)
    }

    private struct ErrorAnswer: Decodable { var error: String? }
    private struct Ignored: Decodable {}
    private struct Given: Decodable {
        struct One: Decodable { var name: String; var kinds: [String] }
        var given: [One]
    }
}
