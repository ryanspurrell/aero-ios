import Foundation

/// What the Shopping screen asks of Organizer. Two things answer it, as for the day (OrganizerBackend): the PC, through Aero's `/private/org`
/// (the six `shop_list*` routes of organizer_service.py, which compute the lists in organizer_lists.py), and the phone's own Organizer, which
/// computes the same answer with `ShopFilter.holds` and keeps the same definitions beside its records. The screen never knows which.
protocol ShoppingBackend {
    var kind: BackendKind { get }
    func load() async throws -> ShopSnapshot
    /// Make a list (`id` nil) or change one; returns its id. `filter` is the rule as JSON ({"in": "self"} for a hand-picked list not made yet).
    func save(id: String?, name: String, filter: JSONValue) async throws -> String
    func remove(id: String) async throws
    /// Where one thing stands with each list.
    func standing(of thing: String) async throws -> [ShopStanding]
    func put(list: String, thing: String) async throws
    func take(list: String, thing: String) async throws
    /// Tick a thing as bought (Organizer's own "complete").
    func bought(_ thing: String) async throws
}

enum ShoppingBackends {
    static func current() -> ShoppingBackend {
        AppInfo.address != nil ? PCShopping(api: OrganizerAPI()) : PhoneShopping(phone: OrganizerBackends.phone, keeper: FileShopListKeeper.standard)
    }
}

// MARK: the PC

/// The PC's lists: the lists, their members and the things are all Organizer's; this only asks and draws. The category a thing shows under in
/// the page is worked out by the page (shopAisleOf); this app has no such guess yet, so a thing with no category of its own is not counted in a
/// "Category is" list here (the PC is sent no hints).
final class PCShopping: ShoppingBackend {
    var kind: BackendKind { .pc }
    private let api: OrganizerAPI

    init(api: OrganizerAPI) { self.api = api }

    private struct Rows: Decodable { var items: [JSONValue] }
    struct Lists: Decodable {
        struct One: Decodable {
            var id: String
            var name: String
            var filter: JSONValue
            var ids: [String]?
            var chosen: Bool?
            var has: Bool?
            var picked: Bool?
        }
        struct Offer: Decodable { var name: String; var why: String?; var filter: JSONValue }
        var lists: [One]?
        var offers: [Offer]?
        var stores: [String]?
    }
    private struct Saved: Decodable { var id: String }
    private struct Done: Decodable {}

    static func thing(_ v: JSONValue) -> ShopThing? {
        guard let o = v.objectValue, let id = o["id"]?.stringValue else { return nil }
        var cost: Double?
        if case .number(let n)? = o["cost"] { cost = n }
        return ShopThing(id: id, title: o["title"]?.stringValue ?? "", store: o["store"]?.stringValue ?? "", category: o["category"]?.stringValue ?? "",
                         want: o["want"]?.stringValue ?? "", type: o["type"]?.stringValue ?? "buy", cost: cost)
    }

    static func snapshot(things: [ShopThing], lists: Lists?) -> ShopSnapshot {
        var snap = ShopSnapshot(things: things)
        snap.lists = (lists?.lists ?? []).map { l in
            ShopList(id: l.id, name: l.name, filter: ShopFilter(json: l.filter), rawFilter: l.filter, members: l.ids ?? [], chosen: l.chosen ?? false)
        }
        snap.offers = (lists?.offers ?? []).compactMap { o in
            ShopFilter(json: o.filter).map { ShopOffer(name: o.name, why: o.why ?? "", filter: $0) }
        }
        snap.stores = lists?.stores ?? ShopView.stores(things)
        return snap
    }

    func load() async throws -> ShopSnapshot {
        let rows = try await api.call("list", ["view": .string("shopping")], as: Rows.self)
        var lists: Lists?
        do { lists = try await api.call("shop_lists", ["aisles": .object([:])], as: Lists.self) }
        catch OrganizerAPI.Failure.server { lists = nil }          // an older Organizer has no lists: the things still show
        return Self.snapshot(things: rows.items.compactMap(Self.thing), lists: lists)
    }

    func save(id: String?, name: String, filter: JSONValue) async throws -> String {
        var args: [String: JSONValue] = ["name": .string(name), "filter": filter]
        if let id { args["id"] = .string(id) }
        return try await api.call("shop_list_set", args, as: Saved.self).id
    }

    func remove(id: String) async throws { _ = try await api.call("shop_list_rm", ["id": .string(id)], as: Done.self) }

    func standing(of thing: String) async throws -> [ShopStanding] {
        let got = try await api.call("shop_lists", ["item": .string(thing), "aisles": .object([:])], as: Lists.self)
        return (got.lists ?? []).map { ShopStanding(id: $0.id, name: $0.name, has: $0.has ?? false, picked: $0.picked ?? false, chosen: $0.chosen ?? false) }
    }

    func put(list: String, thing: String) async throws { _ = try await api.call("shop_list_put", ["list": .string(list), "item": .string(thing)], as: Done.self) }
    func take(list: String, thing: String) async throws { _ = try await api.call("shop_list_take", ["list": .string(list), "item": .string(thing)], as: Done.self) }
    func bought(_ thing: String) async throws { try await api.send("complete", ["id": .string(thing)]) }
}

// MARK: the phone

/// A list as the phone keeps it (organizer_lists.py `ListStore`): a name, a rule, and the whole ids put in it by hand. Never on an item.
struct StoredShopList: Codable, Equatable {
    var name: String
    var filter: JSONValue
    var ids: [String]
    var made: Double
}

/// Where the phone keeps its lists' definitions.
protocol ShopListKeeper {
    func read() -> [String: StoredShopList]
    func write(_ kept: [String: StoredShopList]) throws
}

/// `shopping-lists.json` in the app's Application Support folder, beside the records (complete file protection, as the records are).
final class FileShopListKeeper: ShopListKeeper {
    static let standard = FileShopListKeeper(name: DemoMode.isOn ? "shopping-lists-demo.json" : "shopping-lists.json")
    private let url: URL

    init(name: String) {
        let folder = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        url = folder.appendingPathComponent(name)
        if DemoMode.isOn { try? FileManager.default.removeItem(at: url) }
    }

    func read() -> [String: StoredShopList] {
        guard let data = try? Data(contentsOf: url), let got = try? JSONDecoder().decode([String: StoredShopList].self, from: data) else { return [:] }
        return got
    }

    func write(_ kept: [String: StoredShopList]) throws {
        try JSONEncoder().encode(kept).write(to: url, options: [.atomic, .completeFileProtection])
    }
}

/// Lists in memory only (tests).
final class MemoryShopListKeeper: ShopListKeeper {
    private var kept: [String: StoredShopList] = [:]
    init() {}
    func read() -> [String: StoredShopList] { kept }
    func write(_ k: [String: StoredShopList]) throws { kept = k }
}

/// The phone's own lists: the same rules as the PC's (`ShopFilter`), over the phone's own records, with no PC. Only what the phone may show is
/// listed (PhoneOrganizer.mayShow: unmarked is private). The fields a rule looks at are the record's own (`store`, `category`, `want`).
final class PhoneShopping: ShoppingBackend {
    var kind: BackendKind { .phone }
    let phone: PhoneOrganizer
    private let keeper: ShopListKeeper

    init(phone: PhoneOrganizer, keeper: ShopListKeeper) {
        self.phone = phone
        self.keeper = keeper
    }

    /// The open things to buy, as the shopping view shows them (organizer_service.py `listing(book, "shopping")`), set-aside ones left out.
    static func things(book: OrganizerBook) -> [ShopThing] {
        book.now.filter { $0.value.type == "buy" && $0.value.status == "open" && $0.value.rec["aside"] == nil && PhoneOrganizer.mayShow($0.value, in: book) }
            .map { oid, v in
                var cost: Double?
                if case .number(let n)? = v.rec["cost"] { cost = n }
                return ShopThing(id: String(oid.prefix(8)), oid: oid, title: v.title, store: v.rec["store"]?.stringValue ?? "",
                                 category: v.rec["category"]?.stringValue ?? "", want: v.rec["want"]?.stringValue ?? "", type: "buy", cost: cost)
            }
            .sorted { ($0.title.lowercased(), $0.id) < ($1.title.lowercased(), $1.id) }
    }

    /// The lists and what each holds now, computed from the things and the hand-picked sets each time it is asked.
    static func snapshot(things: [ShopThing], kept: [String: StoredShopList]) -> ShopSnapshot {
        let sets = kept.mapValues { Set($0.ids) }
        var snap = ShopSnapshot(things: things)
        snap.lists = kept.sorted { ($0.value.made, $0.key) < ($1.value.made, $1.key) }.map { id, l in
            let filter = ShopFilter(json: l.filter)
            let members = filter.map { f in things.filter { f.holds($0, sets: sets) }.map(\.id) } ?? []
            return ShopList(id: id, name: l.name, filter: filter, rawFilter: l.filter, members: members, chosen: filter?.reads(set: id) ?? false)
        }
        snap.offers = ShopView.offers(things: things, lists: snap.lists)
        snap.stores = ShopView.stores(things)
        return snap
    }

    func load() async throws -> ShopSnapshot {
        do {
            let book = try phone.store.book()
            await ConnectionMonitor.shared.sawOwn(.reached, backend: .phone)
            return Self.snapshot(things: Self.things(book: book), kept: keeper.read())
        } catch {
            await ConnectionMonitor.shared.sawOwn(.refused, backend: .phone)
            throw error
        }
    }

    /// The id of the list named by `token` (its id, an id's start, or its name), or nil (organizer_lists.py `find`).
    static func find(_ lists: [String: StoredShopList], _ token: String) -> String? {
        if lists[token] != nil { return token }
        let byName = lists.filter { ShopFilter.norm($0.value.name) == ShopFilter.norm(token) }.map(\.key)
        if byName.count == 1 { return byName[0] }
        let starts = lists.keys.filter { !token.isEmpty && $0.hasPrefix(token) }
        return starts.count == 1 ? starts[0] : nil
    }

    func save(id: String?, name: String, filter: JSONValue) async throws -> String {
        var lists = keeper.read()
        let given = id ?? ""
        if !given.isEmpty && lists[given] == nil { throw Refusal("no such list") }
        let label = String(name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(ShopFilter.nameMost))
        if label.isEmpty { throw Refusal("A list has a name.") }
        if lists.contains(where: { ShopFilter.norm($0.value.name) == ShopFilter.norm(label) && $0.key != given }) { throw Refusal("You already have a list with that name.") }
        if given.isEmpty && lists.count >= ShopFilter.listsMost { throw Refusal("That is the most lists.") }
        let lid = given.isEmpty ? String(PhoneStore.newID().prefix(12)) : given
        let cleaned = try ShopFilter.clean(filter, own: lid)
        for k in cleaned.sets where k != lid && lists[k] == nil { throw Refusal("Picked by hand from a list that is not there.") }
        // a list made after another is later than it, even in the same instant (the tabs keep the order they were made in)
        let made = max(Date().timeIntervalSince1970, (lists.values.map(\.made).max() ?? 0) + 0.000001)
        var kept = lists[lid] ?? StoredShopList(name: label, filter: cleaned.json, ids: [], made: made)
        kept.name = label
        kept.filter = cleaned.json
        lists[lid] = kept
        try keeper.write(lists)
        return lid
    }

    func remove(id: String) async throws {
        var lists = keeper.read()
        guard let lid = Self.find(lists, id) else { throw Refusal("no such list") }
        lists.removeValue(forKey: lid)               // only the definition goes: no item is touched
        try keeper.write(lists)
    }

    func standing(of thing: String) async throws -> [ShopStanding] {
        let book = try phone.store.book()
        guard let oid = book.find(thing) else { throw Refusal("That isn't here any more.") }
        let kept = keeper.read()
        let snap = Self.snapshot(things: Self.things(book: book), kept: kept)
        return snap.lists.map { l in
            ShopStanding(id: l.id, name: l.name, has: l.members.contains(String(oid.prefix(8))), picked: kept[l.id]?.ids.contains(oid) ?? false, chosen: l.chosen)
        }
    }

    func put(list: String, thing: String) async throws {
        var lists = keeper.read()
        let book = try phone.store.book()
        guard let lid = Self.find(lists, list) else { throw Refusal("no such list") }
        guard let oid = book.find(thing), book.now[oid]?.type == "buy" else { throw Refusal("only a thing to buy goes in a shopping list") }
        guard let f = ShopFilter(json: lists[lid]?.filter), f.reads(set: lid) else {
            throw Refusal("That list shows things by a rule, not by choice. Change its rule to pick things by hand.")
        }
        var mine = lists[lid]?.ids ?? []
        if !mine.contains(oid) {
            if mine.count >= 2000 { throw Refusal("That list is full.") }
            mine.append(oid)
        }
        lists[lid]?.ids = mine
        try keeper.write(lists)
    }

    func take(list: String, thing: String) async throws {
        var lists = keeper.read()
        let book = try phone.store.book()
        guard let lid = Self.find(lists, list) else { throw Refusal("no such list") }
        guard let oid = book.find(thing) else { throw Refusal("only a thing to buy goes in a shopping list") }
        lists[lid]?.ids = (lists[lid]?.ids ?? []).filter { $0 != oid }       // the id leaves the set, the item stays
        try keeper.write(lists)
    }

    func bought(_ thing: String) async throws { try await phone.send("complete", ["id": .string(thing)]) }
}
