import Foundation

/// Where the screens get their data: the person's server, or invented samples for
/// drawing screenshots with no server.
protocol AeroSource {
    func underway() async throws -> [UnderwayItem]
    func organizerBoard() async throws -> OrganizerBoard
    func understand(_ text: String, choose: [Int: String]) async throws -> QuickAddReading
    func quickAdd(_ text: String, choose: [Int: String], override: [String: Any]) async throws
    func rooms(as manager: String) async throws -> RoomsView
}

extension AeroClient: AeroSource {}

struct SampleSource: AeroSource {
    func underway() async throws -> [UnderwayItem] { Fixtures.underway }
    func organizerBoard() async throws -> OrganizerBoard { Fixtures.board }
    func understand(_ text: String, choose: [Int: String]) async throws -> QuickAddReading { Fixtures.reading }
    func quickAdd(_ text: String, choose: [Int: String], override: [String: Any]) async throws {}
    func rooms(as manager: String) async throws -> RoomsView { Fixtures.rooms }
}
