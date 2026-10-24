import XCTest
@testable import Aero

/// Shopping lists as views. The first group replays, on `ShopFilter`, the cases of Organizer's own tests (projects/organizer/test_list_views.py, the
/// class `Rules`), each named after the theorem of Systems/ListViews.lean it checks; these are Swift checks on invented things to buy, not the proofs.
/// The second group runs the phone's own lists (PhoneShopping) on an in-memory store; the third the screen's model and the PC's answer. All data is invented.
final class ShopRulesTests: XCTestCase {
    private func thing(store: String = "", category: String = "", want: String = "need", type: String = "buy", id: String = "id") -> ShopThing {
        ShopThing(id: id, title: "", store: store, category: category, want: want, type: type)
    }

    private let atoms: [ShopFilter] = [.all, .field(.store, "T&T"), .field(.store, "Costco"), .field(.category, "dairy"), .field(.want, "later"),
                                        .field(.type, "buy"), .member("A"), .member("B")]

    private var filters: [ShopFilter] {
        var out = atoms
        for a in atoms { for b in atoms { out.append(.and([a, b])); out.append(.or([a, b])) } }
        return out
    }

    private var items: [ShopThing] {
        var out: [ShopThing] = []
        for s in ["T&T", "Costco", ""] { for c in ["dairy", ""] { for w in ["need", "later"] { for t in ["buy", "other"] {
            out.append(thing(store: s, category: c, want: w, type: t))
        } } } }
        return out
    }

    func testPutIn_mono_and_putIn_other() {
        for f in filters {
            for it in items.prefix(6) {
                let before: [String: Set<String>] = ["A": ["x"], "B": []]
                let after: [String: Set<String>] = ["A": ["x", "id"], "B": []]
                if f.holds(it, sets: before) { XCTAssertTrue(f.holds(it, sets: after), "\(f)") }                  // putIn_mono: never takes an item out
                if !f.reads(set: "A") { XCTAssertEqual(f.holds(it, sets: before), f.holds(it, sets: after)) }     // putIn_other
            }
        }
    }

    func testHolds_retype_and_kind_filter_reads_kind() {
        for f in filters where !f.readsKind {
            for it in items {
                var other = it
                other.type = "elsewhere"
                XCTAssertEqual(f.holds(it, sets: [:]), f.holds(other, sets: [:]), "\(f)")                        // holds_retype
            }
        }
        let f = ShopFilter.field(.type, "buy")
        XCTAssertTrue(f.readsKind)
        XCTAssertNotEqual(f.holds(thing(), sets: [:]), f.holds(thing(type: "x"), sets: [:]))                      // kind_filter_reads_kind
    }

    func testHolds_id_only_for_picked_by_hand() {
        for it in items {
            XCTAssertTrue(ShopFilter.member("A").holds(it, sets: ["A": ["id"]]))                                  // editing fields keeps membership
            XCTAssertFalse(ShopFilter.member("A").holds(ShopThing(id: "id2", title: "", type: it.type), sets: ["A": ["id"]]))
        }
    }

    func testAll_contains_open() {
        for it in items { XCTAssertTrue(ShopFilter.all.holds(it, sets: [:])) }
    }

    func testValuesAreComparedWithSpacesCollapsedAndCapitalsIgnored() {
        XCTAssertTrue(ShopFilter.field(.store, "t&t").holds(thing(store: "  T&T  "), sets: [:]))
        XCTAssertTrue(ShopFilter.field(.store, "Whole  Foods").holds(thing(store: "whole foods"), sets: [:]))
        XCTAssertFalse(ShopFilter.field(.store, "T&T").holds(thing(store: "T and T"), sets: [:]))
        // a thing with no category of its own counts in the category the screen worked out (the hint), and only then
        XCTAssertFalse(ShopFilter.field(.category, "produce").holds(thing(), sets: [:]))
        XCTAssertTrue(ShopFilter.field(.category, "produce").holds(thing(), sets: [:], hint: "produce"))
        XCTAssertFalse(ShopFilter.field(.category, "produce").holds(thing(category: "dairy"), sets: [:], hint: "produce"))
    }

    func testNear_is_refused_when_saved() {
        XCTAssertThrowsError(try ShopFilter.clean(.object(["near": .string("somewhere")]))) { XCTAssertEqual($0 as? Refusal, Refusal("Lists by place aren't built yet.")) }
    }

    func testCleanFilterRefusesWhatItDoesNotKnow() {
        let bad: [JSONValue] = [.object([:]), .object(["field": .string("colour"), "is": .string("x")]), .object(["and": .array([])]),
                                .object(["or": .string("x")]), .object(["all": .bool(true), "in": .string("x")]), .string("x"), .object(["in": .string("")])]
        for b in bad { XCTAssertThrowsError(try ShopFilter.clean(b), "\(b)") }
        var deep: JSONValue = .object(["all": .bool(true)])
        for _ in 0..<(ShopFilter.depthMost + 2) { deep = .object(["and": .array([deep])]) }
        XCTAssertThrowsError(try ShopFilter.clean(deep))
        XCTAssertEqual(try ShopFilter.clean(.object(["in": .string("self")]), own: "L1"), .member("L1"))
        XCTAssertThrowsError(try ShopFilter.clean(.object(["in": .string("self")])))                               // no id yet
    }

    func testTheFilterSurvivesItsJSON() throws {
        for f in filters.prefix(40) { XCTAssertEqual(ShopFilter(json: f.json), f) }
        for f in filters.prefix(40) { XCTAssertEqual(try ShopFilter.clean(f.json, own: "L"), f) }
        XCTAssertNil(ShopFilter(json: .object(["near": .string("p")])))                                           // a form this app does not know
    }

    func testOffersSkipANameSheHasAndMakeOnePerStore() {
        let things = [thing(store: "T&T"), thing(store: " t&t "), thing(store: "Costco"), thing(store: "")]
        XCTAssertEqual(ShopView.offers(things: things, lists: []).map(\.name), ["Groceries", "T&T", "Costco", "Fruits to try"])
        let have = [ShopList(id: "x", name: "groceries", filter: .all, rawFilter: ShopFilter.all.json, members: [], chosen: false),
                    ShopList(id: "y", name: "Costco", filter: .all, rawFilter: ShopFilter.all.json, members: [], chosen: false)]
        XCTAssertEqual(ShopView.offers(things: things, lists: have).map(\.name), ["T&T", "Fruits to try"])
        XCTAssertEqual(ShopView.offers(things: things, lists: []).first?.filter.json, ShopFilter.or(ShopFilter.foodAisles.map { .field(.category, $0) }).json)
    }
}

final class ShopDraftTests: XCTestCase {
    private func list(_ f: ShopFilter?, raw: JSONValue? = nil, id: String = "L1") -> ShopList {
        ShopList(id: id, name: "Dairy", filter: f, rawFilter: raw ?? f?.json ?? .null, members: [], chosen: f?.reads(set: id) ?? false)
    }

    func testARuleOfRowsIsReadBackAsRows() {
        let d = ShopDraft(list(.and([.field(.store, "T&T"), .field(.category, "dairy")])))
        XCTAssertEqual(d.rules, [ShopRule(kind: .store, value: "T&T"), ShopRule(kind: .category, value: "dairy")])
        XCTAssertTrue(d.all)
        XCTAssertFalse(ShopDraft(list(.or([.field(.store, "T&T"), .member("L1")]))).all)
        XCTAssertEqual(ShopDraft(list(.member("L1"))).rules, [ShopRule(kind: .hand)])
    }

    func testARuleTooTangledToEditIsKeptAsItIs() {
        XCTAssertNil(ShopDraft(list(.and([.or([.all, .all]), .all]))).rules)
        XCTAssertNil(ShopDraft(list(.field(.type, "buy"))).rules)
        XCTAssertNil(ShopDraft(list(nil, raw: .object(["near": .string("p")]))).rules)
    }

    func testTheDraftBecomesTheRuleItCameFrom() {
        let cases: [ShopFilter] = [.field(.store, "T&T"), .member("L1"), .and([.field(.store, "T&T"), .field(.want, "later")]),
                                    .or([.field(.category, "dairy"), .member("L1")])]
        for f in cases { XCTAssertEqual(ShopDraft(list(f)).filter(id: "L1"), f) }
        XCTAssertEqual(ShopDraft().filter(id: nil), .member(ShopFilter.selfSet))                                  // a new hand-picked list
    }

    func testWhatStopsASaveIsSaidInFewWords() {
        var d = ShopDraft()
        XCTAssertEqual(d.problem, "It needs a name")
        d.name = "Fruits"
        XCTAssertNil(d.problem)
        d.rules = []
        XCTAssertEqual(d.problem, "Add a rule")
        d.rules = [ShopRule(kind: .store)]
        XCTAssertEqual(d.problem, "Pick a value for each rule")
        XCTAssertEqual(ShopRule(kind: .category, value: "dairy").words, "Category is Dairy, eggs & cheese")
        XCTAssertEqual(ShopRule(kind: .hand).words, "Picked by hand")
    }
}

/// The phone's own lists, on an in-memory store: the same answers the PC's Organizer gives (test_list_views.py, class Service).
final class PhoneShoppingTests: XCTestCase {
    private var phone: PhoneOrganizer!
    private var shopping: PhoneShopping!

    override func setUpWithError() throws {
        phone = PhoneOrganizer(store: try PhoneStore(), reader: CannedQuickAddReader())
        shopping = PhoneShopping(phone: phone, keeper: MemoryShopListKeeper())
    }

    @discardableResult
    private func add(_ title: String, store: String = "", category: String = "", want: String = "need", type: String = "buy", locked: Bool = false) throws -> String {
        let oid = PhoneStore.newID()
        var rec: [String: JSONValue] = ["type": .string(type), "title": .string(title), "status": .string("open"), "locked": .bool(locked), "want": .string(want)]
        if !store.isEmpty { rec["store"] = .string(store) }
        if !category.isEmpty { rec["category"] = .string(category) }
        _ = try phone.store.put(oid: oid, rec: rec, by: "test", why: "added", replaces: nil)
        return String(oid.prefix(8))
    }

    private func pile() throws {
        try add("Milk", store: "Costco", category: "dairy")
        try add("Dragon fruit", store: "T&T", category: "produce")
        try add("Pears", store: "T&T", category: "produce", want: "later")
        try add("Lamp", store: "IKEA", category: "home")
    }

    private func names(_ listId: String) async throws -> [String] {
        let snap = try await shopping.load()
        return ShopView.things(snap, listId: listId).map(\.title).sorted()
    }

    private func make(_ name: String, _ f: ShopFilter) async throws -> String { try await shopping.save(id: nil, name: name, filter: f.json) }

    func testOnlyOpenOpenThingsToBuyAreInThePile() async throws {
        try pile()
        try add("A task", type: "task")
        try add("Hidden", locked: true)
        let snap = try await shopping.load()
        XCTAssertEqual(snap.things.map(\.title).sorted(), ["Dragon fruit", "Lamp", "Milk", "Pears"])         // a task is not here; unmarked/Locked is private
        XCTAssertEqual(snap.stores, ["Costco", "IKEA", "T&T"])
    }

    func testAListIsComputedNotStored_addList_items_and_removeList_items() async throws {
        try pile()
        let before = try await shopping.load().things
        let tnt = try await make("T&T", .field(.store, "T&T"))
        let afterAdd = try await shopping.load()
        XCTAssertEqual(afterAdd.things, before)                                                              // addList_items
        let costco = try await make("Costco", .field(.store, "Costco"))
        let others = try await names(costco)
        try await shopping.remove(id: tnt)
        let afterRemove = try await shopping.load()
        XCTAssertEqual(afterRemove.things, before)                                                           // removeList_items: no item removed
        let got1 = try await names(costco)
        XCTAssertEqual(got1, others)                                                      // contents_removeList_other
        XCTAssertEqual(afterRemove.lists.map(\.id), [costco])
    }

    func testAnItemIsInSeveralLists_several_lists() async throws {
        try pile()
        let produce = try await make("Produce", .field(.category, "produce"))
        let tnt = try await make("T&T", .field(.store, "T&T"))
        let got2 = try await names(produce)
        XCTAssertEqual(got2, ["Dragon fruit", "Pears"])
        let got3 = try await names(tnt)
        XCTAssertEqual(got3, ["Dragon fruit", "Pears"])
        let snap = try await shopping.load()
        let dragon = try XCTUnwrap(snap.things.first { $0.title == "Dragon fruit" })
        XCTAssertEqual(ShopView.listsOf(dragon, in: snap).map(\.name).sorted(), ["Produce", "T&T"])
        XCTAssertEqual(ShopView.tabs(snap).map(\.title), ["All 4", "Produce 2", "T&T 2"])                     // All first, then each list with its count
    }

    func testAllHoldsEveryOpenItem_all_contains_open() async throws {
        try pile()
        let any = try await make("Everything", .all)
        let snap = try await shopping.load()
        XCTAssertEqual(ShopView.things(snap, listId: "").count, 4)
        XCTAssertEqual(ShopView.things(snap, listId: any).count, 4)
        XCTAssertEqual(ShopView.things(snap, listId: "gone").count, 4)                                       // a tab that is not there shows All
    }

    func testPickedByHandHoldsPointers_putIn_adds_and_take_leaves_the_item() async throws {
        try pile()
        let fruits = try await make("Fruits to try", .member(ShopFilter.selfSet))
        let got4 = try await names(fruits)
        XCTAssertEqual(got4, [])
        let dragon = try add("Durian")
        try await shopping.put(list: fruits, thing: dragon)
        try await shopping.put(list: fruits, thing: dragon)                                                  // twice is once
        let got5 = try await names(fruits)
        XCTAssertEqual(got5, ["Durian"])
        let standing = try await shopping.standing(of: dragon)
        XCTAssertEqual(standing, [ShopStanding(id: fruits, name: "Fruits to try", has: true, picked: true, chosen: true)])
        try await shopping.take(list: fruits, thing: dragon)
        let got6 = try await names(fruits)
        XCTAssertEqual(got6, [])
        let snap = try await shopping.load()
        XCTAssertTrue(snap.things.contains { $0.title == "Durian" })                                         // taken out of the list only
    }

    func testEditingAnItemChangesWhatAFieldListShowsNotWhetherAPickedItemIsIn_editItem_idOnly() async throws {
        let cheese = try add("Cheese", store: "Costco")
        let costco = try await make("Costco", .field(.store, "Costco"))
        let hand = try await make("Picked", .member(ShopFilter.selfSet))
        try await shopping.put(list: hand, thing: cheese)
        let book = try phone.store.book()
        let oid = try XCTUnwrap(book.find(cheese))
        var rec = try XCTUnwrap(book.now[oid]).rec
        rec["store"] = .string("T&T")
        _ = try phone.store.put(oid: oid, rec: rec, by: "test", why: "moved store", replaces: book.now[oid]?.id)
        let got7 = try await names(costco)
        XCTAssertEqual(got7, [])                                                          // what the field list shows follows the edit
        let got8 = try await names(hand)
        XCTAssertEqual(got8, ["Cheese"])                                                    // membership by hand does not
    }

    func testABoughtThingLeavesEveryList() async throws {
        let milk = try add("Milk", category: "dairy")
        let dairy = try await make("Dairy", .field(.category, "dairy"))
        let got9 = try await names(dairy)
        XCTAssertEqual(got9, ["Milk"])
        try await shopping.bought(milk)
        let got10 = try await names(dairy)
        XCTAssertEqual(got10, [])
    }

    func testTheRulesOfAList() async throws {
        try pile()
        await XCTAssertThrowsRefusal("A list has a name.") { _ = try await self.make(" ", .all) }
        let a = try await make("A", .all)
        await XCTAssertThrowsRefusal("You already have a list with that name.") { _ = try await self.make("a", .all) }
        await XCTAssertThrowsRefusal("Lists by place aren't built yet.") { _ = try await self.shopping.save(id: nil, name: "P", filter: .object(["near": .string("x")])) }
        await XCTAssertThrowsRefusal("Picked by hand from a list that is not there.") { _ = try await self.make("Q", .member("nope")) }
        await XCTAssertThrowsRefusal("no such list") { _ = try await self.shopping.save(id: "nope", name: "Z", filter: ShopFilter.all.json) }
        // a rename and a new rule keep the list (and what was put in it)
        let r = try await make("R", .field(.store, "IKEA"))
        let same = try await shopping.save(id: r, name: "Renamed", filter: ShopFilter.field(.store, "Costco").json)
        XCTAssertEqual(same, r)
        let got11 = try await names(r)
        XCTAssertEqual(got11, ["Milk"])
        let snap = try await shopping.load()
        XCTAssertEqual(snap.lists.map(\.name).sorted(), ["A", "Renamed"])
        _ = a
    }

    func testARuleThatIsNotByHandRefusesAPutAndSaysWhy() async throws {
        let milk = try add("Milk", store: "Costco")
        let costco = try await make("Costco", .field(.store, "Costco"))
        await XCTAssertThrowsRefusal("That list shows things by a rule, not by choice. Change its rule to pick things by hand.") {
            try await self.shopping.put(list: costco, thing: milk)
        }
    }

    func testOffersAreOfferedNotMade() async throws {
        try pile()
        let snap = try await shopping.load()
        XCTAssertEqual(snap.lists, [])
        XCTAssertEqual(snap.offers.map(\.name).sorted(), ["Costco", "Fruits to try", "Groceries", "IKEA", "T&T"])
        let o = try XCTUnwrap(snap.offers.first { $0.name == "Fruits to try" })
        let id = try await make(o.name, o.filter)                                                            // she accepts: it is made from the offer as given
        let got12 = try await names(id)
        XCTAssertEqual(got12, [])
        let afterOffers = try await shopping.load().offers
        XCTAssertFalse(afterOffers.contains { $0.name == "Fruits to try" })
    }

    func testTheListsAreKeptBesideTheRecordsAndSurviveAFreshLoad() async throws {
        let keeper = MemoryShopListKeeper()
        let first = PhoneShopping(phone: phone, keeper: keeper)
        let id = try await first.save(id: nil, name: "Dairy", filter: ShopFilter.field(.category, "dairy").json)
        let again = PhoneShopping(phone: phone, keeper: keeper)
        let lists = try await again.load().lists
        XCTAssertEqual(lists.map(\.id), [id])
        XCTAssertEqual(keeper.read()[id]?.ids, [])                                                           // a list holds ids only, never an item
    }
}

/// Fails the way the screen would see a PC that does not answer, or answers.
private final class FakeShopping: ShoppingBackend {
    var kind: BackendKind = .pc
    var fail: Error?
    var snap = ShopSnapshot()
    func load() async throws -> ShopSnapshot { if let fail { throw fail }; return snap }
    func save(id: String?, name: String, filter: JSONValue) async throws -> String { if let fail { throw fail }; return "L1" }
    func remove(id: String) async throws { if let fail { throw fail } }
    func standing(of thing: String) async throws -> [ShopStanding] { if let fail { throw fail }; return [] }
    func put(list: String, thing: String) async throws { if let fail { throw fail } }
    func take(list: String, thing: String) async throws { if let fail { throw fail } }
    func bought(_ thing: String) async throws { if let fail { throw fail } }
}

@MainActor
final class ShoppingModelTests: XCTestCase {
    private func snapshot() -> ShopSnapshot {
        let a = ShopThing(id: "a1", title: "Milk", store: "Costco"), b = ShopThing(id: "b2", title: "Lamp", store: "IKEA")
        let l = ShopList(id: "L1", name: "Costco", filter: .field(.store, "Costco"), rawFilter: ShopFilter.field(.store, "Costco").json, members: ["a1"], chosen: false)
        return ShopSnapshot(things: [a, b], lists: [l], offers: [], stores: ["Costco", "IKEA"])
    }

    func testSwitchingTabsFiltersTheItemsAndAllIsFirst() async {
        let fake = FakeShopping()
        fake.snap = snapshot()
        let model = ShoppingModel(backend: fake)
        await model.load()
        XCTAssertEqual(model.shown.map(\.title), ["Milk", "Lamp"])
        XCTAssertEqual(ShopView.tabs(model.snap).first?.id, "")
        model.choose("L1")
        XCTAssertEqual(model.shown.map(\.title), ["Milk"])
        model.choose("")
        XCTAssertEqual(model.shown.count, 2)
    }

    func testAListRemovedWhileChosenGoesBackToAll() async {
        let fake = FakeShopping()
        fake.snap = snapshot()
        let model = ShoppingModel(backend: fake)
        await model.load()
        model.choose("L1")
        fake.snap.lists = []
        await model.load()
        XCTAssertEqual(model.listId, "")
        XCTAssertEqual(model.shown.count, 2)
    }

    func testAPCThatDoesNotAnswerIsSaidInTheOneShapeWithFindOutWhy() async {
        let fake = FakeShopping()
        fake.fail = OrganizerAPI.Failure.notReached
        let model = ShoppingModel(backend: fake)
        await model.load()
        XCTAssertEqual(model.failure?.text, "Showing your shopping stopped at reaching your PC.")
        XCTAssertEqual(model.failure?.diagnosis, "pc_unreachable")                                           // the key under it is Find out why
        XCTAssertTrue(model.loaded)
        XCTAssertTrue(model.shown.isEmpty)
    }

    func testARefusalIsShownInItsOwnWordsAndNotAsAFailureOfTheWayToThePC() async {
        let fake = FakeShopping()
        fake.fail = OrganizerAPI.Failure.server("You already have a list with that name.")
        let model = ShoppingModel(backend: fake)
        var draft = ShopDraft()
        draft.name = "Dairy"
        let words = await model.save(draft, editing: nil)
        XCTAssertEqual(words, "You already have a list with that name.")
        XCTAssertNil(model.failure)
    }

    func testASavedListBecomesTheChosenTabAndTheSheetCloses() async {
        let fake = FakeShopping()
        fake.snap = snapshot()
        let model = ShoppingModel(backend: fake)
        model.sheet = .own
        var draft = ShopDraft()
        draft.name = "Costco"
        let words = await model.save(draft, editing: nil)
        XCTAssertNil(words)
        XCTAssertEqual(model.listId, "L1")
        XCTAssertNil(model.sheet)
    }

    func testTheNoPCPhoneSaysItWorksListsOutItself() {
        let model = ShoppingModel(backend: FakeShopping())
        XCTAssertEqual(model.backend.kind, .pc)
        XCTAssertEqual(PhoneShopping(phone: PhoneOrganizer(store: try! PhoneStore(), reader: CannedQuickAddReader()), keeper: MemoryShopListKeeper()).kind, .phone)
    }

    func testThePCsAnswerIsReadAsTheScreenNeedsIt() throws {
        let answer = """
        {"lists": [{"id": "L1", "name": "Costco", "filter": {"field": "store", "is": "Costco"}, "count": 1, "ids": ["a1b2c3d4"], "chosen": false},
                   {"id": "L2", "name": "Fruits to try", "filter": {"in": "L2"}, "count": 0, "ids": [], "chosen": true},
                   {"id": "L3", "name": "By place", "filter": {"near": "p"}, "count": 0, "ids": [], "chosen": false}],
         "offers": [{"name": "Groceries", "why": "The food aisles", "filter": {"or": [{"field": "category", "is": "produce"}]}}],
         "stores": ["Costco"], "fields": ["store"], "foods": ["produce"]}
        """
        let lists = try OrganizerDecoder.make().decode(PCShopping.Lists.self, from: Data(answer.utf8))
        let rows: [JSONValue] = [.object(["id": .string("a1b2c3d4"), "title": .string("Milk"), "store": .string("Costco"), "cost": .number(4.5)]), .null]
        let snap = PCShopping.snapshot(things: rows.compactMap(PCShopping.thing), lists: lists)
        XCTAssertEqual(snap.things.map(\.title), ["Milk"])
        XCTAssertEqual(snap.things.first?.cost, 4.5)
        XCTAssertEqual(snap.lists.map(\.name), ["Costco", "Fruits to try", "By place"])
        XCTAssertEqual(snap.lists[0].members, ["a1b2c3d4"])
        XCTAssertTrue(snap.lists[1].chosen)
        XCTAssertNil(snap.lists[2].filter)                                                                    // a rule this app does not know is kept as it is
        XCTAssertEqual(snap.lists[2].rawFilter, .object(["near": .string("p")]))
        XCTAssertEqual(snap.offers.map(\.name), ["Groceries"])
        XCTAssertEqual(ShopView.things(snap, listId: "L1").map(\.title), ["Milk"])
        XCTAssertEqual(ShopView.tabs(snap).first?.label, "All, 1 thing")
        XCTAssertEqual(ShopView.tabs(snap)[1].label, "Costco, 1 thing")
    }
}

private func XCTAssertThrowsRefusal(_ words: String, _ body: @escaping () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
    do {
        try await body()
        XCTFail("expected a refusal: \(words)", file: file, line: line)
    } catch let r as Refusal {
        XCTAssertEqual(r.words, words, file: file, line: line)
    } catch {
        XCTFail("expected a refusal, got \(error)", file: file, line: line)
    }
}
