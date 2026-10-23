import Foundation

// Photos, read-only: what the PC's Photos routes answer, as the server code writes it (projects/core/home/.local/bin/fingus_core_photos.py,
// `month_items`, `item_info`, `album_shown`, `add_library_routes`; passed on by aero_web.py `private_photo_lib_*`). Nothing here is kept on the
// phone; the answers are read again each time. Every id, name and date in the tests is invented.

/// A number the server may send as a number, a string, or nothing (Immich's `duration` is a millisecond number in one version and
/// "0:00:12.345000" in an older one: `animated()` in fingus_core_photos.py handles both).
private extension KeyedDecodingContainer {
    func flag(_ key: Key) -> Bool { (try? decode(Bool.self, forKey: key)) ?? false }
    func text(_ key: Key) -> String? { try? decode(String.self, forKey: key) }
    func whole(_ key: Key) -> Int {
        if let n = try? decode(Int.self, forKey: key) { return n }
        if let d = try? decode(Double.self, forKey: key) { return Int(d) }
        return 0
    }
    func number(_ key: Key) -> Double? {
        if let d = try? decode(Double.self, forKey: key) { return d }
        if let s = try? decode(String.self, forKey: key) { return PhotosFormat.milliseconds(s) }
        return nil
    }
}

/// One month of the library and how many photos and videos it holds.
struct PhotoMonth: Decodable, Equatable, Identifiable {
    var month: String
    var count: Int
    var id: String { month }
    enum CodingKeys: String, CodingKey { case month, count }
    init(month: String, count: Int) { self.month = month; self.count = count }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = try c.decode(String.self, forKey: .month)
        count = c.whole(.count)
    }
}

/// One photo or video in a month's grid.
struct PhotoItem: Decodable, Equatable, Identifiable {
    var id: String
    /// Local time as the server writes it: "2026-10-05T12:03:09".
    var taken: String
    var video: Bool
    var favourite: Bool
    var live: Bool
    /// A video's length in milliseconds, if the server said.
    var ms: Double?
    /// Width over height, 1 when not said.
    var ratio: Double
    var place: String
    /// A short version of the picture, for its address; nil while the server has made no thumbnail yet.
    var version: String?
    var animated: Bool
    /// Her cover-up setting covers it: it is drawn as a plain cover and its picture is never asked for.
    var covered: Bool
    enum CodingKeys: String, CodingKey { case id, taken, video, fav, live, ms, ratio, place, v, anim, blur }
    init(id: String, taken: String = "", video: Bool = false, favourite: Bool = false, live: Bool = false, ms: Double? = nil, ratio: Double = 1,
         place: String = "", version: String? = nil, animated: Bool = false, covered: Bool = false) {
        self.id = id; self.taken = taken; self.video = video; self.favourite = favourite; self.live = live; self.ms = ms; self.ratio = ratio
        self.place = place; self.version = version; self.animated = animated; self.covered = covered
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        taken = c.text(.taken) ?? ""
        video = c.flag(.video)
        favourite = c.flag(.fav)
        live = c.text(.live) != nil
        ms = c.number(.ms)
        ratio = c.number(.ratio) ?? 1
        place = c.text(.place) ?? ""
        version = c.text(.v)
        animated = c.flag(.anim)
        covered = c.flag(.blur)
    }
}

/// `GET private/photos/lib/months`: the months, newest first; with `first=1` the newest month's items come too.
struct PhotoMonthsAnswer: Decodable, Equatable {
    var months: [PhotoMonth]
    var total: Int
    var first: PhotoMonthAnswer?
    enum CodingKeys: String, CodingKey { case months, total, first }
    init(months: [PhotoMonth], total: Int, first: PhotoMonthAnswer? = nil) { self.months = months; self.total = total; self.first = first }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        months = (try? c.decode([PhotoMonth].self, forKey: .months)) ?? []
        total = c.whole(.total)
        first = try? c.decode(PhotoMonthAnswer.self, forKey: .first)
    }
}

/// `GET private/photos/lib/month?month=YYYY-MM`: one month's items, newest first.
struct PhotoMonthAnswer: Decodable, Equatable {
    var month: String
    var items: [PhotoItem]
    enum CodingKeys: String, CodingKey { case month, items }
    init(month: String, items: [PhotoItem]) { self.month = month; self.items = items }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        month = c.text(.month) ?? ""
        items = (try? c.decode([PhotoItem].self, forKey: .items)) ?? []
    }
}

/// One album: name, how many, a cover (nil when hidden or none), first and last dates.
struct PhotoAlbum: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var count: Int
    var cover: String?
    var start: String
    var end: String
    var covered: Bool
    enum CodingKeys: String, CodingKey { case id, name, count, cover, start, end, blur }
    init(id: String, name: String, count: Int, cover: String? = nil, start: String = "", end: String = "", covered: Bool = false) {
        self.id = id; self.name = name; self.count = count; self.cover = cover; self.start = start; self.end = end; self.covered = covered
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.text(.name) ?? ""
        count = c.whole(.count)
        cover = c.text(.cover)
        start = c.text(.start) ?? ""
        end = c.text(.end) ?? ""
        covered = c.flag(.blur)
    }
}

struct PhotoAlbumsAnswer: Decodable, Equatable {
    var albums: [PhotoAlbum]
    enum CodingKeys: String, CodingKey { case albums }
    init(albums: [PhotoAlbum]) { self.albums = albums }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        albums = (try? c.decode([PhotoAlbum].self, forKey: .albums)) ?? []
    }
}

/// `GET private/photos/lib/item/<id>`: what the info sheet shows. The fields the server also sends (content tags, faces, errors, the Money line)
/// are not read.
struct PhotoInfo: Decodable, Equatable {
    struct InAlbum: Decodable, Equatable { var id: String; var name: String? }
    struct Person: Decodable, Equatable { var pid: Int?; var name: String? }
    var id: String
    var name: String
    var taken: String
    var place: String
    var camera: String
    var shot: String
    var size: Double?
    var pixels: [Int]
    var albums: [InAlbum]
    var people: [Person]
    var said: String?
    enum CodingKeys: String, CodingKey { case id, name, taken, place, camera, shot, size, pixels, albums, people, description }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.text(.name) ?? ""
        taken = c.text(.taken) ?? ""
        place = c.text(.place) ?? ""
        camera = c.text(.camera) ?? ""
        shot = c.text(.shot) ?? ""
        size = c.number(.size)
        pixels = (try? c.decode([Int].self, forKey: .pixels)) ?? []
        albums = (try? c.decode([InAlbum].self, forKey: .albums)) ?? []
        people = (try? c.decode([Person].self, forKey: .people)) ?? []
        said = c.text(.description)
    }
}

// MARK: words and dates, with no screen in them

enum PhotosWords {
    static let title = "Photos"
    static let library = "Library"
    static let albums = "Albums"
    static let needsPC = "Photos live on your PC. Connect it to see them here."
    static let connectPC = "Connect your PC"
    static let couldntLoad = "Couldn't load photos."
    static let locked = "These photos are Locked."
    static let unlock = "Unlock in Aero"
    static let signIn = "Sign in to Aero to see photos."
    static let tryAgain = "Try again"
    static let empty = "No photos yet"
    static let noAlbums = "No albums yet"
    static let covered = "Covered"
    static let videoInAero = "Videos play in Aero."
    static let openInAero = "Open in Aero"
    static let info = "Info"
    static let previous = "Previous photo"
    static let next = "Next photo"
    static let home = "Home"
}

enum PhotosFormat {
    private static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]

    /// "2026-10" as "October 2026"; anything else as it came.
    static func monthTitle(_ month: String) -> String {
        let p = month.split(separator: "-")
        guard p.count == 2, let y = Int(p[0]), let m = Int(p[1]), (1...12).contains(m) else { return month }
        return "\(months[m - 1]) \(y)"
    }

    /// "2026-10-05T12:03:09" as "5 October 2026, 12:03"; the date alone when no time was given.
    static func when(_ taken: String) -> String {
        let halves = taken.split(separator: "T", maxSplits: 1).map(String.init)
        let d = (halves.first ?? "").split(separator: "-")
        guard d.count == 3, let y = Int(d[0]), let m = Int(d[1]), let day = Int(d[2]), (1...12).contains(m) else { return taken }
        let date = "\(day) \(months[m - 1]) \(y)"
        guard halves.count == 2, halves[1].count >= 5 else { return date }
        return date + ", " + String(halves[1].prefix(5))
    }

    /// Milliseconds from a number's text, or from "H:MM:SS.ffffff" (the older Immich's duration).
    static func milliseconds(_ text: String) -> Double? {
        if let n = Double(text) { return n }
        let parts = text.split(separator: ":").map { Double($0) }
        guard parts.count == 3, let h = parts[0], let m = parts[1], let s = parts[2] else { return nil }
        return ((h * 60 + m) * 60 + s) * 1000
    }

    /// A video's length as "0:12" or "1:02:03".
    static func length(_ ms: Double?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let t = Int((ms / 1000).rounded())
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// A file size in the units a person reads.
    static func bytes(_ n: Double?) -> String? {
        guard let n, n > 0 else { return nil }
        if n >= 1_000_000 { return String(format: "%.1f MB", n / 1_000_000) }
        return String(format: "%.0f KB", max(1, n / 1000))
    }
}

// MARK: the walk (ScreenWalk.lean: enter, back, tap a step in the header)

/// A place inside Photos. The tabs are two things Photos holds; an album is held by Albums; a photo is held by the library or by an album.
enum PhotosPlace: Equatable {
    case library
    case albums
    case album(id: String, name: String)
    case photo(id: String)

    var label: String {
        switch self {
        case .library: return PhotosWords.library
        case .albums: return PhotosWords.albums
        case .album(_, let name): return name.isEmpty ? PhotosWords.albums : name
        case .photo: return "Photo"
        }
    }
}

/// Where she is inside Photos, as the list of things she walked into after Home and Photos. The header shows Home, Photos, then these. Back takes
/// the last one off; tapping a step of the header is the same as pressing Back until there (`tap_is_backs`).
struct PhotosWalk: Equatable {
    /// Never empty: the first place is the tab she is on.
    private(set) var places: [PhotosPlace] = [.library]

    var current: PhotosPlace { places.last ?? .library }
    var isAtTab: Bool { places.count == 1 }

    /// The header: "Home", "Photos", then each place's name.
    var crumbs: [String] { [PhotosWords.home, PhotosWords.title] + places.map(\.label) }

    /// Going into something she can see on this page (an album, a photo).
    mutating func enter(_ place: PhotosPlace) {
        switch place {
        case .library, .albums: return          // tabs are siblings, reached by `switchTab`
        default: places.append(place)
        }
    }

    /// Back: one step out. At a tab there is nothing to take off (the part's Back key leaves to Home); returns whether it moved.
    @discardableResult
    mutating func back() -> Bool {
        guard places.count > 1 else { return false }
        places.removeLast()
        return true
    }

    /// A tab is another thing Photos holds, not a step: it replaces the walk.
    mutating func switchTab(_ tab: PhotosPlace) {
        guard tab == .library || tab == .albums else { return }
        places = [tab]
    }

    /// What tapping the header's step `k` does: nil means Home (the part is left); otherwise the walk it leaves.
    func tapped(_ k: Int) -> PhotosWalk? {
        if k <= 0 { return nil }
        var w = self
        // crumbs: 0 Home, 1 Photos, 2.. places; Photos is the tab she is on
        let keep = max(1, k - 1)
        while w.places.count > keep { w.places.removeLast() }
        return w
    }
}
