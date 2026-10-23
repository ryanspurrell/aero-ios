import Foundation

/// How a screen of Photos stands. `PhotosPhase.of` is the one place an error becomes a state, so the screen has no failure handling of its own.
enum PhotosPhase: Equatable {
    case loading
    case ready
    /// Locked photos need Face ID in Aero first.
    case locked
    case signedOut
    /// The PC cannot be reached or answered with an error: a short line, and "Find out why" for the rest. `detail` is only what the system or the
    /// server said, shown when she asks.
    case failed(detail: String)

    static func of(_ error: Error) -> PhotosPhase {
        switch error as? PhotosAPI.Failure {
        case .locked?: return .locked
        case .notSignedIn?: return .signedOut
        case .unreachable(let d)?, .server(let d)?: return .failed(detail: d)
        case .noAddress?: return .failed(detail: "No PC address is set.")
        case .unreadable?: return .failed(detail: "The PC's answer could not be read.")
        case nil: return .failed(detail: error.localizedDescription)
        }
    }
}

/// The library, or one album: its months, and each month's items once asked for. Read again each time the screen opens; nothing is stored.
@MainActor
final class PhotosMonthsModel: ObservableObject {
    let album: String?
    private let api: PhotosAPI
    @Published private(set) var phase = PhotosPhase.loading
    @Published private(set) var months: [PhotoMonth] = []
    @Published private(set) var items: [String: [PhotoItem]] = [:]
    @Published private(set) var failedMonths: Set<String> = []
    private var asking: Set<String> = []

    init(api: PhotosAPI, album: String? = nil) { self.api = api; self.album = album }

    /// Every loaded item in the order shown (newest month first), for swiping from one photo to the next.
    var flat: [PhotoItem] { months.flatMap { items[$0.month] ?? [] } }

    func load() async {
        phase = .loading
        do {
            let answer = try await api.months(album: album)
            months = answer.months
            items = [:]
            failedMonths = []
            if let first = answer.first { items[first.month] = first.items }
            phase = .ready
        } catch {
            phase = PhotosPhase.of(error)
        }
    }

    /// One month's items, when its section comes into view.
    func loadMonth(_ month: String) async {
        guard items[month] == nil, !asking.contains(month) else { return }
        asking.insert(month)
        defer { asking.remove(month) }
        do {
            items[month] = try await api.month(month, album: album).items
            failedMonths.remove(month)
        } catch {
            failedMonths.insert(month)
            if case .locked = PhotosPhase.of(error) { phase = .locked }
        }
    }

    func retryMonth(_ month: String) async {
        failedMonths.remove(month)
        await loadMonth(month)
    }
}

/// The albums.
@MainActor
final class PhotosAlbumsModel: ObservableObject {
    private let api: PhotosAPI
    @Published private(set) var phase = PhotosPhase.loading
    @Published private(set) var albums: [PhotoAlbum] = []

    init(api: PhotosAPI) { self.api = api }

    func load() async {
        phase = .loading
        do {
            albums = try await api.albums()
            phase = .ready
        } catch {
            phase = PhotosPhase.of(error)
        }
    }
}

/// One photo's info, asked for when the info sheet opens.
@MainActor
final class PhotoInfoModel: ObservableObject {
    private let api: PhotosAPI
    @Published private(set) var phase = PhotosPhase.loading
    @Published private(set) var info: PhotoInfo?

    init(api: PhotosAPI) { self.api = api }

    func load(_ id: String) async {
        phase = .loading
        do {
            info = try await api.item(id)
            phase = .ready
        } catch {
            phase = PhotosPhase.of(error)
        }
    }
}
