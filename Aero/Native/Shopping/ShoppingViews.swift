import SwiftUI

// The native Shopping screen: the open things to buy, with the lists as underline tabs (All first, the selector style she chose), a sheet to
// make, rename, change the rules of and remove a list, and the lists each thing is in as chips. Look is Aero's (Tokens.swift, FingusUI.swift);
// the web page's Shopping screen (aero_web.py shopListTabs, shopListSheet, shopChips) is the reference, and projects/aero/
// design__shopping_ui_2026-10-06.md. Every key is a visible tap; a list is told by its name and its count, never by colour alone.

/// Underline tabs of the app (the day's tabs): the chosen one has its line; each is a button with a label VoiceOver reads with its count.
struct ShopTabs: View {
    let tabs: [ShopTab]
    let selected: String
    var select: (String) -> Void
    var plus: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Look.Space.pad) {
                    ForEach(tabs) { t in
                        Button { select(t.id) } label: {
                            Text(t.title).fx(Look.Size.tab, style: .subheadline)
                                .foregroundStyle(selected == t.id ? Look.Palette.fg : Look.Palette.soft)
                                .padding(.vertical, Look.Space.snug)
                                .overlay(alignment: .bottom) { if selected == t.id { Rectangle().fill(Look.Palette.fg).frame(height: 3).offset(y: 1) } }
                                .frame(minHeight: Look.Space.sizeTap)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(t.label)
                        .accessibilityAddTraits(selected == t.id ? .isSelected : [])
                    }
                    if let plus {
                        Button(action: plus) {
                            Image(systemName: "plus").font(.system(size: 16, weight: .bold)).foregroundStyle(Look.Palette.soft)
                                .frame(minWidth: Look.Space.sizeTap, minHeight: Look.Space.sizeTap)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Make a list")
                    }
                }
            }
            Rectangle().fill(Look.Palette.rule).frame(height: 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Lists")
    }
}

struct ShoppingScreen: View {
    @StateObject private var model: ShoppingModel
    var back: () -> Void

    init(back: @escaping () -> Void, backend: ShoppingBackend = ShoppingBackends.current()) {
        self.back = back
        _model = StateObject(wrappedValue: ShoppingModel(backend: backend))
    }

    var body: some View {
        VStack(spacing: 0) {
                topRow
                Text("Shopping").fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Look.Space.gutter).padding(.bottom, Look.Space.tight)
                    .accessibilityAddTraits(.isHeader)
                if !model.snap.lists.isEmpty {
                    ShopTabs(tabs: ShopView.tabs(model.snap),
                             selected: model.listId, select: { model.choose($0) }, plus: { model.sheet = .make })
                        .padding(.horizontal, Look.Space.gutter)
                }
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Look.Space.snug) { content }
                        // full width, leading: without it the column is as wide as its widest line and sits centred, so a short line starts
                        // further in than the title above it (seen in the first Shopping picture, 2026-10-23)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Look.Space.gutter).padding(.top, Look.Space.gap).padding(.bottom, Look.Space.clearance)
                }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NewBox(onAdded: { Task { await model.load() } })
                .padding(.horizontal, Look.Space.gutter).padding(.bottom, Look.Space.floatBottom)
        }
        .fingusGround()
        .toolbar(.hidden, for: .navigationBar)
        .task { await model.load() }
        .sheet(item: $model.sheet) { which in
            switch which {
            case .make: MakeListSheet(model: model)
            case .own: ListSheet(model: model, list: nil)
            case .edit(let id): ListSheet(model: model, list: model.list(id))
            case .item(let id): ThingListsSheet(model: model, thing: model.thing(id))
            }
        }
    }

    private var topRow: some View {
        HStack {
            Button(action: back) {
                HStack(spacing: Look.Space.hair) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)); Text("Today").fx(Look.Size.tab, style: .subheadline) }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
            }
            .accessibilityLabel("Back to today")
            Spacer()
            ConnectionIsland()
        }
        .padding(.horizontal, Look.Space.gutter)
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure {
            Text(failure.text).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            FailureKeys(tryAgain: "Try again", diagnosis: failure.diagnosis) { Task { await model.load() } }
        }
        if let note = model.note {
            Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                .task(id: note) { try? await Task.sleep(nanoseconds: 4_000_000_000); model.clearNote() }
        }
        if let list = model.chosenList {
            HStack(spacing: Look.Space.tight) {
                FingusKey(title: "Edit list", prominent: false) { model.sheet = .edit(list.id) }
                    .accessibilityLabel("Edit the list \(list.name)")
                if list.filter == nil {
                    Text("This list's rule is kept as it is").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                }
            }
        }
        if !model.loaded {
            if model.failure == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, Look.Space.section) }
        } else if model.shown.isEmpty && model.failure == nil {
            Text(model.listId.isEmpty ? "Nothing to buy. Type it in the box below." : "Nothing in this list now").fx(Look.Size.calm, style: .subheadline)
                .foregroundStyle(Look.Palette.soft)
        } else {
            ForEach(model.shown) { t in ThingRow(model: model, thing: t) }
        }
        if model.loaded && model.snap.lists.isEmpty && model.failure == nil {
            FingusKey(title: "Make a list", prominent: false) { model.sheet = .make }
                .accessibilityHint("A list is a saved question about everything to buy. Nothing is moved.")
        }
        if model.loaded && model.backend.kind == .phone && model.failure == nil {
            Text("Lists are worked out on this phone from what it holds").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        }
    }
}

/// One thing to buy: a key to tick it bought, its name and where it is from, and chips for the lists it is in.
struct ThingRow: View {
    @ObservedObject var model: ShoppingModel
    let thing: ShopThing

    var body: some View {
        let inLists = ShopView.listsOf(thing, in: model.snap)
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            HStack(spacing: Look.Space.snug) {
                Button { Task { await model.bought(thing) } } label: {
                    Image(systemName: "circle").font(.system(size: 22, weight: .regular)).foregroundStyle(Look.Palette.soft)
                        .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel("Mark \(thing.title) bought")
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(thing.title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                    if !thing.store.isEmpty { Text(thing.store).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                }
                Spacer(minLength: 0)
            }
            if !inLists.isEmpty || !model.snap.lists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Look.Space.tight) {
                        ForEach(inLists) { l in chip(l.name, symbol: "tag", label: "In the list \(l.name). Opens the lists \(thing.title) is in.") }
                        if model.snap.lists.contains(where: { $0.chosen && !$0.members.contains(thing.id) }) {
                            chip("Add to a list", symbol: "plus", label: "Add \(thing.title) to a list")
                        }
                    }
                }
            }
        }
        .padding(Look.Space.snug).fingusCard(radius: Look.Bubble.radiusRow)
        .accessibilityElement(children: .contain)
    }

    private func chip(_ title: String, symbol: String, label: String) -> some View {
        Button { model.sheet = .item(thing.id) } label: {
            HStack(spacing: Look.Space.hair) {
                Image(systemName: symbol).font(.system(size: 11, weight: .bold)).accessibilityHidden(true)
                Text(title).fx(Look.Size.pill, style: .footnote).lineLimit(1)
            }
            .foregroundStyle(Look.Palette.fg)
            .padding(.horizontal, Look.Space.snug).frame(minHeight: Look.Space.sizeTap - 8)
            .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.accent.opacity(0.35)))
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel(label)
    }
}

// MARK: the sheets

/// The frame of the three sheets: a title, content, a Close key, on the page ground.
struct ShopSheetFrame<Content: View>: View {
    let title: String
    var close: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.gap) {
                HStack {
                    Text(title).fx(Look.Size.head, style: .title2).foregroundStyle(Look.Palette.fg).accessibilityAddTraits(.isHeader)
                    Spacer()
                    FingusKey(title: "Close", prominent: false, action: close)
                }
                content
            }
            .padding(Look.Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fingusGround()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// Make a list: what Organizer offers (nothing is made until one is tapped), or her own.
struct MakeListSheet: View {
    @ObservedObject var model: ShoppingModel
    @State private var fail = ""

    var body: some View {
        ShopSheetFrame(title: "Make a list", close: { model.sheet = nil }) {
            ForEach(model.snap.offers) { o in
                Button { Task { fail = await model.make(o) ?? "" } } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: Look.Space.hair) {
                            Text(o.name).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                            Text(o.why).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        }
                        Spacer()
                        Image(systemName: "plus").foregroundStyle(Look.Palette.soft).accessibilityHidden(true)
                    }
                    .padding(Look.Space.pad).frame(minHeight: Look.Space.sizeTap).fingusCard(radius: Look.Bubble.radiusRow)
                }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel("Make the list \(o.name). \(o.why).")
            }
            Button { model.sheet = .own } label: {
                HStack {
                    VStack(alignment: .leading, spacing: Look.Space.hair) {
                        Text("Your own").fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                        Text("Choose what goes in it").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Look.Palette.soft).accessibilityHidden(true)
                }
                .padding(Look.Space.pad).frame(minHeight: Look.Space.sizeTap).fingusCard(radius: Look.Bubble.radiusRow)
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel("Your own list. Choose what goes in it.")
            if !fail.isEmpty { Text(fail).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft) }
        }
    }
}

/// A list's sheet: its name, how its rules combine, the rules, Save, and Remove. Saved only on Save (aero_web.py `shopListSheet`).
struct ListSheet: View {
    @ObservedObject var model: ShoppingModel
    let list: ShopList?
    @State private var draft: ShopDraft

    init(model: ShoppingModel, list: ShopList?) {
        self.model = model
        self.list = list
        _draft = State(initialValue: list.map { ShopDraft($0) } ?? ShopDraft())
    }

    var body: some View {
        ShopSheetFrame(title: list?.name ?? "Your own list", close: { model.sheet = nil }) {
            TextField("", text: $draft.name, prompt: Text("Name").foregroundColor(Look.Palette.inputText))
                .fx(Look.Size.input, style: .body).foregroundStyle(Look.Palette.fg)
                .padding(Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).fill(Look.Palette.input))
                .accessibilityLabel("List name")
            if let rules = draft.rules {
                if rules.count > 1 {
                    ShopTabs(tabs: [ShopTab(id: "all", title: "All of these", label: "All of these rules must hold"), ShopTab(id: "any", title: "Any of these", label: "Any one of these rules is enough")],
                             selected: draft.all ? "all" : "any", select: { draft.all = ($0 == "all") })
                }
                ForEach(Array(rules.enumerated()), id: \.offset) { n, rule in ruleRow(n, rule) }
                Menu {
                    ForEach(ShopRule.Kind.allCases, id: \.self) { k in Button(k.words) { draft.rules?.append(ShopRule(kind: k)) } }
                } label: { keyLabel("Add a rule", symbol: "plus") }
                    .accessibilityLabel("Add a rule")
            } else {
                Text("This list's rule is kept as it is. You can rename it or remove it.").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            }
            FingusKey(title: "Save") { Task { save() } }
            if let list {
                Button { Task { await removeTapped(list) } } label: {
                    Text(draft.armed ? "Remove? Tap again" : "Remove list").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.now)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel(draft.armed ? "Remove the list \(list.name). Tap again to confirm. Nothing on it is deleted." : "Remove the list \(list.name)")
            }
            if !draft.fail.isEmpty { Text(draft.fail).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft) }
        }
    }

    private func save() {
        if let problem = draft.problem { draft.fail = problem; return }
        Task { draft.fail = await model.save(draft, editing: list) ?? "" }
    }

    private func removeTapped(_ list: ShopList) async {
        if !draft.armed { draft.armed = true; return }
        draft.fail = await model.remove(list) ?? ""
    }

    private func keyLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: Look.Space.hair) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold))
            Text(title).fx(Look.Size.pill, style: .footnote)
        }
        .foregroundStyle(Look.Palette.fg).padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
        .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.card))
    }

    /// One rule: the kind (a menu), its value (a menu), and a key to take it out.
    private func ruleRow(_ n: Int, _ rule: ShopRule) -> some View {
        HStack(spacing: Look.Space.tight) {
            Menu {
                ForEach(ShopRule.Kind.allCases, id: \.self) { k in Button(k.words) { draft.rules?[n] = ShopRule(kind: k) } }
            } label: { keyLabel(rule.kind.words, symbol: "chevron.up.chevron.down") }
                .accessibilityLabel("Rule \(n + 1), \(rule.kind.words)")
            if rule.kind != .hand {
                Menu {
                    ForEach(values(rule.kind)) { v in Button(v.words) { draft.rules?[n].value = v.id } }
                } label: { keyLabel(valueWords(rule), symbol: "chevron.up.chevron.down") }
                    .accessibilityLabel("Rule \(n + 1) value, \(valueWords(rule))")
            }
            Spacer(minLength: 0)
            Button { draft.rules?.remove(at: n) } label: {
                Image(systemName: "minus.circle").font(.system(size: 20)).foregroundStyle(Look.Palette.soft)
                    .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel("Remove rule \(n + 1), \(rule.words)")
        }
    }

    private func values(_ kind: ShopRule.Kind) -> [ShopChoice] {
        switch kind {
        case .store: return model.snap.stores.map { ShopChoice(id: $0, words: $0) }
        case .category: return ShopAisles.all
        case .want: return ShopAisles.wants
        case .hand: return []
        }
    }

    private func valueWords(_ rule: ShopRule) -> String {
        rule.value.isEmpty ? "Pick one" : (values(rule.kind).first { $0.id == rule.value }?.words ?? rule.value)
    }
}

/// The lists one thing is in: the ones it was put in by hand, with a key that takes it out; the ones it is in by their rule, said in words; and
/// a key to add it to another. Nothing is moved, and the thing stays in All.
struct ThingListsSheet: View {
    @ObservedObject var model: ShoppingModel
    let thing: ShopThing?
    @State private var standing: [ShopStanding]?
    @State private var fail = ""

    var body: some View {
        ShopSheetFrame(title: thing?.title ?? "Lists", close: { model.sheet = nil }) {
            if let thing {
                if let standing {
                    let picked = standing.filter { $0.picked }
                    let byRule = standing.filter { $0.has && !$0.picked }
                    let spare = standing.filter { $0.chosen && !$0.picked }
                    if picked.isEmpty && byRule.isEmpty && spare.isEmpty {
                        Text("It isn't in a list").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    }
                    ForEach(picked) { l in
                        row(l.name, "Taken out only of this list. It stays in All.", key: "Take out", label: "Take \(thing.title) out of \(l.name)") {
                            fail = await model.take(thing, from: l) ?? ""
                            await reload(thing)
                        }
                    }
                    ForEach(byRule) { l in
                        Text("In \(l.name) by its rule").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    }
                    ForEach(spare) { l in
                        row(l.name, "Picked by hand", key: "Add", label: "Add \(thing.title) to \(l.name)") {
                            fail = await model.put(thing, in: l) ?? ""
                            await reload(thing)
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if !fail.isEmpty { Text(fail).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft) }
            } else {
                Text("That isn't here any more").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            }
        }
        .task { if let thing { await reload(thing) } }
    }

    private func reload(_ thing: ShopThing) async { standing = await model.standing(of: thing) ?? standing }

    private func row(_ name: String, _ note: String, key: String, label: String, go: @escaping () async -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: Look.Space.hair) {
                Text(name).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            }
            Spacer()
            FingusKey(title: key, prominent: false) { Task { await go() } }.accessibilityLabel(label)
        }
        .padding(Look.Space.pad).fingusCard(radius: Look.Bubble.radiusRow)
    }
}
