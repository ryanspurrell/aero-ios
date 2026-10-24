import Foundation

// Shopping lists as views over the things to buy, in Swift. The simplest model: Organizer keeps one pile of things to buy. A list is a saved
// question asked of the pile ("store is T&T", "category is dairy", "the ones I put in Fruits to try"), so asking again always gives the
// current answer, an item can be in several lists, and nothing is ever moved. A list is a name and a filter; it is never kept on an item.
//
// The rules are projects/foundations/FingusFoundations/FingusFoundations/Systems/ListViews.lean (View.holds, View.refs, View.readsKind,
// View.idOnly, and the theorems addList_items, removeList_items, several_lists, putIn_mono, putIn_other, all_contains_open, holds_retype,
// editItem_idOnly). `ShopFilter.holds` follows `View.holds` and `organizer_lists.py` `holds`; ShoppingTests replays the cases of
// projects/organizer/test_list_views.py on it.
//
// Where it lives and why (standing rule 29, builder_brief_standing_rules.md; projects/core/design__core_principles_2026-10-09.md): lists belong to
// Organizer, which owns the things to buy, not to Core (Core is a translation layer, not a database) and not to Aero, a thin shell. With a PC
// the PC computes and keeps them (organizer_lists.py through Aero's /private/org, the six shop_list* routes), and this app only draws what it
// is told. With no PC the phone's own Organizer holds the same definitions (PhoneShopLists) and this file's evaluator computes the same answer.
// A thing is stored only if it cannot be a view (Aryn, 2026-10-23, 8:43 pm): the list definitions are the only thing stored; membership is not.
// Placement considered against: per-pointer consent (every item stays a pointer through the one drawer; a list holds ids only), Relay (nothing
// here is AI: the rules are deterministic), the privacy ladder (the phone shows only what PhoneOrganizer.mayShow lets it).

/// The fields a rule may look at (Lean `Field`).
enum ShopField: String, CaseIterable {
    case store, category, want, type
}

/// A thing to buy as a list reads it: its ids, and the four fields. No list and no place (Lean `Item`).
struct ShopThing: Identifiable, Hashable {
    /// The short id (first 8 characters), as the API names a record.
    var id: String
    /// The whole id when the phone has it (hand-picked sets hold whole ids); the short id otherwise.
    var oid: String
    var title: String
    var store: String
    var category: String
    var want: String
    var type: String
    var cost: Double?

    init(id: String, oid: String? = nil, title: String, store: String = "", category: String = "", want: String = "", type: String = "buy", cost: Double? = nil) {
        self.id = id; self.oid = oid ?? id; self.title = title; self.store = store; self.category = category; self.want = want; self.type = type; self.cost = cost
    }

    /// What a record says for a field, `hint` standing in for a category it does not have (organizer_lists.py `value_of`).
    func value(_ field: ShopField, hint: String? = nil) -> String {
        switch field {
        case .type: return ShopFilter.norm(type.isEmpty ? "buy" : type)
        case .category: return ShopFilter.norm(category.isEmpty ? (hint ?? "") : category)
        case .store: return ShopFilter.norm(store)
        case .want: return ShopFilter.norm(want)
        }
    }
}

/// A list's rule (Lean `View`): everything, a field equal to a value, picked by hand, and, or. "Related to a place" (`near`) is a named hook in
/// Organizer and is refused when saved, so no list silently shows nothing.
indirect enum ShopFilter: Equatable {
    case all
    case field(ShopField, String)
    case member(String)
    case and([ShopFilter])
    case or([ShopFilter])

    static let nameMost = 60, listsMost = 40, widthMost = 12, depthMost = 4
    static let nearNotBuilt = "Lists by place aren't built yet."
    /// In a filter being saved: this list's own set (its id is made first).
    static let selfSet = "self"
    /// Aero's food aisle ids (organizer_lists.py FOOD_AISLES).
    static let foodAisles = ["produce", "bakery", "meat", "dairy", "frozen", "pantry", "snacks"]

    /// Spaces collapsed and capitals ignored; the only fold applied (organizer_lists.py `norm`).
    static func norm(_ v: String) -> String {
        v.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }

    /// Whether an open thing to buy is in the view (Lean `View.holds`). `sets`: {list id: whole ids put in it by hand}.
    func holds(_ item: ShopThing, sets: [String: Set<String>], hint: String? = nil) -> Bool {
        switch self {
        case .all: return true
        case .field(let f, let v): return item.value(f, hint: hint) == ShopFilter.norm(v)
        case .member(let k): return sets[k]?.contains(item.oid) ?? false
        case .and(let parts): return parts.allSatisfy { $0.holds(item, sets: sets, hint: hint) }
        case .or(let parts): return parts.contains { $0.holds(item, sets: sets, hint: hint) }
        }
    }

    /// Whether the rule reads list `id`'s hand-picked set (Lean `View.refs`).
    func reads(set id: String) -> Bool {
        switch self {
        case .member(let k): return k == id
        case .and(let p), .or(let p): return p.contains { $0.reads(set: id) }
        default: return false
        }
    }

    /// Whether the rule reads the kind (type) field by name (Lean `View.readsKind`).
    var readsKind: Bool {
        switch self {
        case .field(let f, _): return f == .type
        case .and(let p), .or(let p): return p.contains { $0.readsKind }
        default: return false
        }
    }

    /// The list ids whose hand-picked sets the rule reads.
    var sets: [String] {
        switch self {
        case .member(let k): return [k]
        case .and(let p), .or(let p): return p.flatMap { $0.sets }
        default: return []
        }
    }

    // MARK: JSON, as Organizer keeps and takes it

    var json: JSONValue {
        switch self {
        case .all: return .object(["all": .bool(true)])
        case .field(let f, let v): return .object(["field": .string(f.rawValue), "is": .string(v)])
        case .member(let k): return .object(["in": .string(k)])
        case .and(let p): return .object(["and": .array(p.map { $0.json })])
        case .or(let p): return .object(["or": .array(p.map { $0.json })])
        }
    }

    /// A rule from JSON cut to the forms above, or the words to show (organizer_lists.py `clean_filter`, word for word). `own`: this list's id,
    /// which {"in": "self"} is turned into.
    static func clean(_ raw: JSONValue, own: String? = nil, depth: Int = 0) throws -> ShopFilter {
        if depth > depthMost { throw Refusal("That rule goes too deep.") }
        let shapeWords = "A rule is one of: everything, a field is a value, picked by hand, and, or."
        guard let o = raw.objectValue, o.count == 1 || Set(o.keys) == ["field", "is"] else { throw Refusal(shapeWords) }
        if o["all"]?.boolValue == true && o.count == 1 { return .all }
        if let name = o["field"] {
            guard let f = name.stringValue.flatMap(ShopField.init(rawValue:)), let v = o["is"]?.stringValue else {
                throw Refusal("A rule can look at: \(ShopField.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            return .field(f, String(v.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefix(120)))
        }
        if let k = o["in"] {
            if k.stringValue == selfSet {
                guard let own, !own.isEmpty else { throw Refusal("That list has no id yet.") }
                return .member(own)
            }
            guard let s = k.stringValue, !s.isEmpty else { throw Refusal("Picked by hand from which list?") }
            return .member(String(s.prefix(64)))
        }
        if o["near"] != nil { throw Refusal(nearNotBuilt) }
        for key in ["and", "or"] {
            if let parts = o[key] {
                guard let list = parts.arrayValue, !list.isEmpty, list.count <= widthMost else { throw Refusal("A rule joins 1 to \(widthMost) rules.") }
                let cleaned = try list.map { try clean($0, own: own, depth: depth + 1) }
                return key == "and" ? .and(cleaned) : .or(cleaned)
            }
        }
        throw Refusal(shapeWords)
    }

    /// A rule as Organizer sent it; nil when it is not one this app knows (an older or newer Organizer). The list is then kept as it is.
    init?(json: JSONValue?, depth: Int = 0) {
        guard let json, depth <= ShopFilter.depthMost + 1, let o = json.objectValue else { return nil }
        if o["all"]?.boolValue == true { self = .all; return }
        if let f = o["field"]?.stringValue.flatMap(ShopField.init(rawValue:)), let v = o["is"]?.stringValue { self = .field(f, v); return }
        if let k = o["in"]?.stringValue { self = .member(k); return }
        for key in ["and", "or"] {
            if let list = o[key]?.arrayValue {
                var parts: [ShopFilter] = []
                for p in list { guard let q = ShopFilter(json: p, depth: depth + 1) else { return nil }; parts.append(q) }
                self = key == "and" ? .and(parts) : .or(parts)
                return
            }
        }
        return nil
    }
}

/// Words that are safe to show, from a rule or a list the person made wrong.
struct Refusal: LocalizedError, Equatable {
    var words: String
    init(_ words: String) { self.words = words }
    var errorDescription: String? { words }
}

/// A list: a name and a rule, plus what the rule gives now (computed, never kept on an item).
struct ShopList: Identifiable, Equatable {
    var id: String
    var name: String
    /// nil when this app does not know the rule's form: the list is shown and can be renamed or removed, and its rule is kept as it is.
    var filter: ShopFilter?
    var rawFilter: JSONValue
    /// The short ids of the things in it now.
    var members: [String]
    /// Whether the rule reads this list's own hand-picked set, so things can be put in and taken out by hand.
    var chosen: Bool
    var count: Int { members.count }
}

/// A list Organizer suggests and does not make (Aryn accepts one, or none).
struct ShopOffer: Identifiable, Equatable {
    var name: String
    var why: String
    var filter: ShopFilter
    var id: String { name }
}

/// Where one thing stands with each list (`shop_lists` with `item`): in it by hand (can be taken out), in it by rule, or free to be put in.
struct ShopStanding: Identifiable, Equatable {
    var id: String
    var name: String
    var has: Bool
    var picked: Bool
    var chosen: Bool
}

/// Everything the screen draws, from either backend.
struct ShopSnapshot: Equatable {
    var things: [ShopThing] = []
    var lists: [ShopList] = []
    var offers: [ShopOffer] = []
    var stores: [String] = []
}

// MARK: what the screen shows

/// One underline tab: its id (empty is All), what it shows, and what VoiceOver says.
struct ShopTab: Identifiable, Equatable {
    var id: String
    var title: String
    var label: String
}

/// One choice of a value menu: what is kept, and what is said.
struct ShopChoice: Identifiable, Equatable {
    var id: String
    var words: String
}

enum ShopView {
    /// The things in the tab chosen: All (an empty id) is every open thing (Lean `all_contains_open`); a list is what its rule gives now.
    static func things(_ snap: ShopSnapshot, listId: String) -> [ShopThing] {
        guard !listId.isEmpty, let list = snap.lists.first(where: { $0.id == listId }) else { return snap.things }
        let members = Set(list.members)
        return snap.things.filter { members.contains($0.id) }
    }

    /// The lists one thing is in, for the chips on its row.
    static func listsOf(_ thing: ShopThing, in snap: ShopSnapshot) -> [ShopList] {
        snap.lists.filter { $0.members.contains(thing.id) }
    }

    /// The tabs: All first (the app's underline tabs), then each list with its count, and the words VoiceOver reads for each.
    static func tabs(_ snap: ShopSnapshot) -> [ShopTab] {
        func things(_ n: Int) -> String { "\(n) \(n == 1 ? "thing" : "things")" }
        var out = [ShopTab(id: "", title: "All \(snap.things.count)", label: "All, " + things(snap.things.count))]
        for l in snap.lists { out.append(ShopTab(id: l.id, title: "\(l.name) \(l.count)", label: "\(l.name), " + things(l.count))) }
        return out
    }

    /// A list that was removed while it was chosen goes back to All.
    static func settled(_ listId: String, in snap: ShopSnapshot) -> String {
        snap.lists.contains(where: { $0.id == listId }) ? listId : ""
    }

    /// What Organizer suggests (organizer_lists.py `offers`): Groceries (the food aisles), one per store found on the open things, and Fruits to try
    /// (picked by hand). A name she already has is not offered again.
    static func offers(things: [ShopThing], lists: [ShopList]) -> [ShopOffer] {
        let have = Set(lists.map { ShopFilter.norm($0.name) })
        var out = [ShopOffer(name: "Groceries", why: "The food aisles", filter: .or(ShopFilter.foodAisles.map { .field(.category, $0) }))]
        var seen = Set<String>()
        for t in things {
            let s = t.store.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !s.isEmpty, !seen.contains(ShopFilter.norm(s)) {
                seen.insert(ShopFilter.norm(s))
                out.append(ShopOffer(name: s, why: "Things from " + s, filter: .field(.store, s)))
            }
        }
        out.append(ShopOffer(name: "Fruits to try", why: "You pick what goes in it", filter: .member(ShopFilter.selfSet)))
        return out.filter { !have.contains(ShopFilter.norm($0.name)) }
    }

    static func stores(_ things: [ShopThing]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in things {
            let s = t.store.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !s.isEmpty, seen.insert(s).inserted { out.append(s) }
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

// MARK: the sheet's draft

/// Aero's aisles, in the order a shop is walked (aero_web.py SHOP_AISLES: id and words), for the "Category is" rule.
enum ShopAisles {
    static let all: [ShopChoice] = [
        ShopChoice(id: "produce", words: "Produce"), ShopChoice(id: "bakery", words: "Bakery"), ShopChoice(id: "meat", words: "Meat & fish"),
        ShopChoice(id: "dairy", words: "Dairy, eggs & cheese"), ShopChoice(id: "frozen", words: "Frozen"), ShopChoice(id: "pantry", words: "Pantry"),
        ShopChoice(id: "snacks", words: "Snacks & drinks"), ShopChoice(id: "household", words: "Household"),
        ShopChoice(id: "personal", words: "Personal care & health"), ShopChoice(id: "home", words: "Home & furniture"),
        ShopChoice(id: "clothes", words: "Clothes"), ShopChoice(id: "tech", words: "Electronics"), ShopChoice(id: "other", words: "Other")]
    static let wants: [ShopChoice] = [ShopChoice(id: "need", words: "To buy"), ShopChoice(id: "optional", words: "Optional"), ShopChoice(id: "later", words: "Later")]
}

/// One row of a list's rule in the sheet (aero_web.py SHOP_RULE_KINDS).
struct ShopRule: Equatable {
    enum Kind: String, CaseIterable {
        case store, category, want, hand
        var words: String {
            switch self {
            case .store: return "Store is"
            case .category: return "Category is"
            case .want: return "Wanted as"
            case .hand: return "Picked by hand"
            }
        }
    }
    var kind: Kind
    var value: String = ""

    /// "Store is T&T", "Category is Dairy, eggs & cheese", "Picked by hand".
    var words: String {
        if kind == .hand { return kind.words }
        let shown: String
        switch kind {
        case .category: shown = ShopAisles.all.first { $0.id == value }?.words ?? value
        case .want: shown = ShopAisles.wants.first { $0.id == value }?.words ?? value
        default: shown = value
        }
        return kind.words + " " + shown
    }
}

/// The sheet's draft of a list: saved only on Save (aero_web.py `shopListSheet`).
struct ShopDraft: Equatable {
    var name = ""
    var all = true
    /// nil when the rule is too tangled to edit here: the list keeps its rule, and can be renamed or removed.
    var rules: [ShopRule]? = [ShopRule(kind: .hand)]
    var armed = false
    var fail = ""

    init() {}

    /// A list's draft; a rule that is not one the rows can say (nested, or a form this app does not know) leaves `rules` nil.
    init(_ list: ShopList) {
        name = list.name
        guard let f = list.filter else { rules = nil; return }
        func atom(_ a: ShopFilter) -> ShopRule? {
            switch a {
            case .member: return ShopRule(kind: .hand)
            case .field(let field, let v): return ShopRule.Kind(rawValue: field.rawValue).map { ShopRule(kind: $0, value: v) }
            default: return nil
            }
        }
        switch f {
        case .and(let p), .or(let p):
            let parts = p.compactMap(atom)
            guard parts.count == p.count else { rules = nil; return }
            rules = parts
            if case .or = f { all = false }
        default:
            if let one = atom(f) { rules = [one] } else { rules = nil }
        }
    }

    /// The rule to save for the rows; `id` is the list's id, or nil for a list not made yet ({"in": "self"}).
    func filter(id: String?) -> ShopFilter? {
        guard let rules else { return nil }
        let parts: [ShopFilter] = rules.map { r in
            switch r.kind {
            case .hand: return .member(id ?? ShopFilter.selfSet)
            case .store: return .field(.store, r.value)
            case .category: return .field(.category, r.value)
            case .want: return .field(.want, r.value)
            }
        }
        return parts.count == 1 ? parts[0] : (all ? .and(parts) : .or(parts))
    }

    /// What stops a Save, in the words shown; nil when it can go.
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "It needs a name" }
        if let rules, rules.isEmpty { return "Add a rule" }
        if let rules, rules.contains(where: { $0.kind != .hand && $0.value.isEmpty }) { return "Pick a value for each rule" }
        return nil
    }
}
