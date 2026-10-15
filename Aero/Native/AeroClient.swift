import Foundation

/// Asks the person's own Aero server. `base` is the address they entered (with any
/// path prefix); `token` is the device token the server gave this phone, sent as
/// `Authorization: Bearer`. Nothing is built in: both come from the phone.
struct AeroClient {
    var base: URL
    var token: String

    enum Failure: Error { case status(Int), notFound }

    private func request(_ path: String, body: [String: Any]? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base.appendingPathComponent("")) else { throw Failure.notFound }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure.status(http.statusCode)
        }
        return data
    }

    private func chosen(_ choose: [Int: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in choose { out[String(key)] = value }
        return out
    }

    private func organizer(_ name: String, _ args: [String: Any] = [:]) async throws -> Data {
        try await request("private/org", body: ["name": name, "args": args])
    }

    func underway() async throws -> [UnderwayItem] {
        try JSONDecoder().decode(UnderwayAnswer.self, from: try await request("underway.json")).items
    }

    func organizerBoard() async throws -> OrganizerBoard {
        try JSONDecoder().decode(OrganizerBoard.self, from: try await organizer("board"))
    }

    func understand(_ text: String, choose: [Int: String]) async throws -> QuickAddReading {
        let data = try await organizer("understand", ["text": text, "choose": chosen(choose)])
        return try JSONDecoder().decode(QuickAddReading.self, from: data)
    }

    /// `override` is what the person changed in the form: title, date (yyyy-MM-dd),
    /// time (HH:mm), project.
    func quickAdd(_ text: String, choose: [Int: String], override: [String: Any]) async throws {
        _ = try await organizer("quickadd", ["text": text, "choose": chosen(choose), "override": override])
    }

    func rooms(as manager: String = "fingus") async throws -> RoomsView {
        let data = try await request("rooms.json?as=\(manager)")
        return try JSONDecoder().decode(RoomsAnswer.self, from: data).view ?? RoomsView(unread: nil, rooms: [], sections: [])
    }
}
