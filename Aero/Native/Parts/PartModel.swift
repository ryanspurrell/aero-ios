import Foundation

// The part registry's rules, with no screen in them. Every part of Fingus is a plug-in the person turns on or off: it has an id, a name, an icon,
// a colour, a root view and what it needs (a PC, or the phone alone). Home holds the parts she added as tiles.
//
// Plug-in here means "turned on or off", never "downloaded". Apple's App Review Guideline 2.5.2 says apps "may not ... download, install, or
// execute code which introduces or changes features or functionality of the app" (https://developer.apple.com/app-store/review/guidelines/,
// read 2026-10-23), so every part's root view is compiled into the app (`PartRoot`) and only the list of which are on is data. A part Core
// has that this build has no view for opens in the web view, which is the server's page, not code the app runs.
//
// The Holarchy below mirrors projects/foundations/FingusFoundations/FingusFoundations/Systems/ScreenWalk.lean (W-E): Home is the root and a part is
// a tile on it; adding or removing one leaves every other walk valid. The tests carry the Lean theorems' names.

/// What a part needs to work.
enum PartNeed: String, Equatable {
    /// The phone alone is enough (it has its own Core).
    case phoneOk
    /// Only a PC can do it; with none, the part is not offered (never offered and then failing).
    case pcOnly
}

/// The root view a part opens to, chosen among those compiled into this build.
enum PartRoot: String, Equatable {
    case organizer, chat, photos
    /// No native view yet: the server's page, in the web view.
    case web
}

/// One part's identity.
struct PartInfo: Identifiable, Equatable {
    var id: String
    var name: String
    /// Core's icon word ("chat", "check", "photos"...).
    var icon: String
    /// The part's colour as Core serves it ("#9ee0c0"), or nil.
    var colourHex: String?
    var needs: PartNeed
    var root: PartRoot
    /// Core marks the part Locked (Boards): it is listed by name only and opens behind the web view's unlock.
    var locked = false
}

// MARK: the parts the phone has on its own, and Core's list

enum PartCatalog {
    /// The phone's own parts: they work with no PC (Core on every device, design__ios_without_a_pc_2026-10-15). Chats are kept and answered on the
    /// PC, so Chats need one. Colours are Core's `PARTS` values (fingus_core_parts.py: lime #dfe35a, mint #9ee0c0).
    static let own: [PartInfo] = [
        PartInfo(id: "organizer", name: "Organizer", icon: "check", colourHex: "#dfe35a", needs: .phoneOk, root: .organizer),
        PartInfo(id: "messages", name: "Chats", icon: "chat", colourHex: "#9ee0c0", needs: .pcOnly, root: .chat),
        // Photos (slice 3, read-only): the library is kept on the PC and read through its Photos routes, so it needs one. lavender #cdb6ee.
        PartInfo(id: "photos", name: "Photos", icon: "photos", colourHex: "#cdb6ee", needs: .pcOnly, root: .photos),
    ]

    /// What `/look.json` serves under "parts": {id: {name, icon, colour, hex, privacy, group?}}. Home's own entries (Needs you, Check-in) carry no
    /// group and are not screens, so they are left out.
    private struct Entry: Decodable {
        var name: String
        var icon: String
        var hex: String?
        var privacy: String?
        var group: String?
    }
    private struct LookParts: Decodable { var parts: [String: Entry]? }

    /// Core's parts from `/look.json` bytes; nil when the bytes are not that shape. Sorted by name, so the list is the same each time.
    static func decodeCore(_ data: Data) -> [PartInfo]? {
        guard let look = try? JSONDecoder().decode(LookParts.self, from: data), let parts = look.parts else { return nil }
        return parts
            .filter { $0.value.group != nil }
            .map { id, e in
                let mine = own.first { $0.id == id }
                return PartInfo(id: id, name: e.name, icon: e.icon, colourHex: e.hex, needs: mine?.needs ?? .pcOnly, root: mine?.root ?? .web,
                                locked: e.privacy == "locked")
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The parts to offer: the phone's own first, then Core's others. With no list from Core (no PC, or it did not answer) just the phone's own.
    static func merged(core: [PartInfo]?) -> [PartInfo] {
        guard let core else { return own }
        let ownIDs = Set(own.map(\.id))
        let ownNow = own.map { mine in core.first { $0.id == mine.id } ?? mine }
        return ownNow + core.filter { !ownIDs.contains($0.id) }
    }
}

// MARK: which parts are on

/// The ordered list of ids she has added. Pure: the stored form is a comma-joined string (ids are plain words).
enum PartsSelection {
    /// On when nothing was ever chosen: Organizer, which is what the app opens on today (picked, not grounded: her question 7 on which parts are
    /// on by default is open).
    static let standard = ["organizer"]

    static func decode(_ raw: String?) -> [String] {
        guard let raw else { return standard }
        return raw.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }
    static func encode(_ ids: [String]) -> String { ids.joined(separator: ",") }

    /// Add at the end; a part already there stays where it is.
    static func adding(_ ids: [String], _ id: String) -> [String] { ids.contains(id) ? ids : ids + [id] }
    static func removing(_ ids: [String], _ id: String) -> [String] { ids.filter { $0 != id } }

    /// Whether the part can be offered now.
    static func offered(_ part: PartInfo, hasPC: Bool) -> Bool { part.needs == .phoneOk || hasPC }

    /// The tiles Home draws: the added parts in the order added, the ones this build does not know or a missing PC rules out left out (kept in the
    /// list, so they return in place).
    static func tiles(added: [String], parts: [PartInfo], hasPC: Bool) -> [PartInfo] {
        added.compactMap { id in parts.first { $0.id == id } }.filter { offered($0, hasPC: hasPC) }
    }
}

// MARK: Home as a graph (ScreenWalk.lean, W-A and W-E)

/// Things and what each holds; `root` is Home.
struct Holarchy {
    var root: String
    var kids: (String) -> [String]

    /// The thing a walk ends at (Home for the empty walk).
    func cur(_ walk: [String]) -> String { walk.last ?? root }

    /// A walk from `n` is valid when each step goes into something the thing before it holds.
    func walk(from n: String, _ w: [String]) -> Bool {
        guard let m = w.first else { return true }
        return kids(n).contains(m) && walk(from: m, Array(w.dropFirst()))
    }
    /// The walks the header can show: valid ones from Home.
    func ok(_ w: [String]) -> Bool { walk(from: root, w) }

    /// Add a plug-in part as a new tile on Home (W-E `addTile`).
    func addTile(_ p: String) -> Holarchy {
        let r = root, k = kids
        return Holarchy(root: r, kids: { n in n == r ? k(n) + [p] : k(n) })
    }
    /// Take a plug-in tile away from Home (W-E `removeTile`).
    func removeTile(_ p: String) -> Holarchy {
        let r = root, k = kids
        return Holarchy(root: r, kids: { n in n == r ? k(n).filter { $0 != p } : k(n) })
    }

    /// A recent place is reached by a command and moves only if its walk is still a place (a plug-in may have gone): otherwise the walk stays.
    func openRecent(from current: [String], recent: [String]) -> [String] { ok(recent) ? recent : current }
}

extension Holarchy {
    /// The app's Home: the added parts are its tiles; what is inside a part is that part's own.
    static func home(tiles: [String], inside: @escaping (String) -> [String] = { _ in [] }) -> Holarchy {
        Holarchy(root: "home", kids: { n in n == "home" ? tiles : inside(n) })
    }
}
