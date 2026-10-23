import Foundation
import CoreLocation
import SwiftUI

/// What the Location screen holds: the answer of the routes, the day being looked at, the tab, and the last thing the map was told to look at.
/// Read-only: nothing here is sent to the server but the three reads of `MapsAPI`.
@MainActor
final class MapsStore: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed(String), needsPC }
    enum Tab: String { case timeline = "Timeline", places = "Places" }

    /// A command to the camera. `serial` changes with every command so the same one twice still moves the map.
    struct Aim: Equatable {
        enum Kind: Equatable {
            case here
            case day
            case point(lat: Double, lon: Double)
            case trip(from: Double, to: Double)
        }
        var serial = 0
        var kind: Kind = .day
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var overview: MapsOverview?
    @Published private(set) var day: MapsDay?
    @Published private(set) var dayKey = ""
    @Published private(set) var info = MapsInfo()
    @Published var tab: Tab = .timeline
    @Published private(set) var look = Aim()
    @Published private(set) var dayFailure: String?

    private let api: MapsAPI
    private let hasAddress: () -> Bool

    init(api: MapsAPI = MapsAPI(), hasAddress: @escaping () -> Bool = { AppInfo.address != nil }) {
        self.api = api
        self.hasAddress = hasAddress
    }

    /// Today as the PC counts it, so the day stepper agrees with Core when the phone is in another time zone.
    var today: String { overview?.today.day ?? MapsText.dayKey(Date()) }

    var isToday: Bool { dayKey == today }

    func load() async {
        guard hasAddress() else { phase = .needsPC; return }
        phase = overview == nil ? .loading : phase
        do {
            let got = try await api.overview()
            overview = got
            if dayKey.isEmpty || dayKey == got.today.day { day = got.today; dayKey = got.today.day }
            phase = .ready
            if let more = try? await api.info() { info = more }
            send(.day)
        } catch let failure as MapsAPI.Failure {
            phase = failure == .noAddress ? .needsPC : .failed(failure.words)
        } catch {
            phase = .failed(MapsAPI.Failure.unreachable.words)
        }
    }

    func send(_ kind: Aim.Kind) { look = Aim(serial: look.serial + 1, kind: kind) }

    /// The map looks where she is, or at the day's whole path (or where she is when the day has none).
    func lookHere() { if overview?.now.known == true { send(.here) } }
    func lookDay() { send(.day) }

    func step(_ by: Int) async {
        let key = MapsText.shift(dayKey, by: by)
        if key > today { return }
        await go(to: key)
    }

    func go(to key: String) async {
        guard let overview else { return }
        dayFailure = nil
        if key == overview.today.day { day = overview.today; dayKey = key; send(.day); return }
        do {
            day = try await api.day(key)
            dayKey = key
            send(.day)
        } catch let failure as MapsAPI.Failure {
            dayFailure = failure.words
        } catch {
            dayFailure = MapsAPI.Failure.unreachable.words
        }
    }

    /// The line the map says of itself, in one quiet line, or nil.
    var mapSays: String? {
        if info.tiles?.unreachable == true { return MapsText.vpnDown }
        if info.fetching != nil { return MapsText.gettingMap }
        return nil
    }
}
