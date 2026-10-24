import SwiftUI

/// What the trip planner changes. The "Before the trip" tab fills it from the store; "Try a situation" fills it from its own copy, so a situation
/// never touches the real trip.
struct TripActions {
    var addPlanned: (String, Int?) -> Void
    var setHeight: (Int, Int?) -> Void
    var removePlanned: (Int) -> Void
    var addTool: (String, Int?) -> Void
    var setReach: (Int, Int?) -> Void
    var removeTool: (Int) -> Void
    var startPlanned: ((Int) -> Void)? = nil
}

/// "Before the trip": the planned samples with their heights, the ladders and tools with their reach, and whether the trip is ready. Rules: Part F2
/// of FieldSample.lean (`sampleReach`, `tripReady`, `needed`; `ready_iff`, `unknown_height_not_ready`, `unconfirmed_reach_not_ready`,
/// `cannotReach_names`). A ladder said to exist with no height is asked as "How tall is it?" and never counts as reaching.
struct TripPlanner: View {
    let plan: Run
    let tools: [ToolEntry]
    let actions: TripActions
    let practice: Bool

    @State private var newPlace = ""
    @State private var newHeight = ""
    @State private var newTool = ""

    private var reaches: Tools { tools.map(\.reach) }

    var body: some View {
        let ready = tripReady(reaches, plan)
        Group {
            resultCard(ready)
            FieldCard(title: "Ladders and tools") {
                if tools.isEmpty { FieldNote("Nothing listed yet. Add what you will have, or what the client says they have.") }
                ForEach(tools) { t in ToolRow(tool: t, actions: actions) }
                FieldInput(label: "Add a ladder or tool", text: $newTool, prompt: "For example Client's ladder")
                FieldButton(title: "Add", symbol: "plus", tint: .plain, enabled: !newTool.trimmingCharacters(in: .whitespaces).isEmpty) {
                    actions.addTool(newTool.trimmingCharacters(in: .whitespaces), nil)
                    newTool = ""
                }
            }
            FieldCard(title: "Planned samples") {
                if plan.isEmpty { FieldNote("Add each sample you plan to take, with how high it is.") }
                ForEach(plan) { s in PlannedRow(sample: s, reach: sampleReach(reaches, s), actions: actions) }
                FieldInput(label: "Place", text: $newPlace, prompt: practice ? "For example Building 1, Room 101" : "Where the sample is")
                FieldInput(label: "How high is it? cm", text: $newHeight, keyboard: .numberPad)
                FieldButton(title: "Add sample", symbol: "plus", tint: .plain, enabled: !newPlace.isEmpty && (newHeight.isEmpty || Int(newHeight) != nil)) {
                    actions.addPlanned(newPlace, newHeight.isEmpty ? nil : Int(newHeight))
                    newPlace = ""; newHeight = ""
                }
            }
        }
    }

    // MARK: the answer

    @ViewBuilder private func resultCard(_ ready: Equip) -> some View {
        let tallest = plan.isEmpty ? 0 : needed(plan)
        let best = tools.compactMap(\.reach).max()
        let words: (head: String, detail: String, symbol: String, hue: String) = {
            if plan.isEmpty { return ("Nothing planned yet", "Add the samples you plan to take.", "list.bullet", "grey") }
            switch ready {
            case .ready:
                return ("Ready", "A ladder or tool you have measured reaches every sample. The highest is \(FieldWording.cm(tallest)).", "checkmark.circle", "green")
            case .cannotReach(let id):
                let s = plan.first(where: { $0.id == id })
                let h = s?.height ?? 0
                return ("Out of reach",
                        "\(s?.place ?? "A sample") is \(FieldWording.cm(h)) up. " + (best.map { "The most you can reach is \(FieldWording.cm($0))." } ?? "") + " Bring something that reaches \(FieldWording.cm(tallest)).",
                        "xmark.circle", "red")
            case .unknown:
                var missing: [String] = []
                for t in tools where t.reach == nil { missing.append("How tall is \(t.name)?") }
                if tools.isEmpty { missing.append("What will you reach with?") }
                for s in plan where s.height == nil { missing.append("How high is \(s.place.isEmpty ? "sample \(s.id)" : s.place)?") }
                return ("Not sure yet", missing.joined(separator: " "), "questionmark.circle", "yellow")
            }
        }()
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            StatePill(symbol: words.symbol, text: words.head)
            Text(words.detail).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.ink).fixedSize(horizontal: false, vertical: true)
            if !plan.isEmpty { Text("Reach needed: \(FieldWording.cm(tallest))").ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.ink) }
        }
        .accessibilityElement(children: .combine)
        .padding(Look.Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubble(words.hue, radius: Look.Bubble.radiusItem)
    }
}

/// One ladder or tool. Without a height it asks "How tall is it?"; the box takes the reach in cm.
struct ToolRow: View {
    let tool: ToolEntry
    let actions: TripActions
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            HStack {
                Text(tool.name).ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.fg)
                Spacer(minLength: 0)
                Button { actions.removeTool(tool.id) } label: {
                    Image(systemName: "minus.circle").frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                }
                .foregroundStyle(Look.Palette.soft)
                .accessibilityLabel("Remove \(tool.name)")
            }
            FieldInput(label: "Reach of \(tool.name), cm", text: $text, keyboard: .numberPad, prompt: "How tall is it?")
        }
        .onAppear { sync() }
        .onChange(of: text) { t in
            let v = t.isEmpty ? nil : Int(t)
            if v != tool.reach, t.isEmpty || v != nil { actions.setReach(tool.id, v) }
        }
        .onChange(of: tool.reach) { _ in sync() }
    }

    private func sync() {
        let want = tool.reach.map(String.init) ?? ""
        if (text.isEmpty ? nil : Int(text)) != tool.reach { text = want }
    }
}

/// One planned sample with its height box and whether it can be reached.
struct PlannedRow: View {
    let sample: Sample
    let reach: Four
    let actions: TripActions
    @State private var text = ""

    var body: some View {
        let r = FieldWording.reachWords(reach)
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            HStack {
                Text(sample.place.isEmpty ? "Sample \(sample.id)" : sample.place).ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.fg)
                Spacer(minLength: 0)
                StatePill(symbol: r.symbol, text: r.headline)
            }
            FieldInput(label: "Height of \(sample.place.isEmpty ? "sample \(sample.id)" : sample.place), cm", text: $text, keyboard: .numberPad, prompt: "How high is it?")
            FieldButtonRow {
                if let start = actions.startPlanned { FieldButton(title: "Start pump", symbol: "play.circle", tint: .plain) { start(sample.id) } }
                FieldButton(title: "Remove", symbol: "minus.circle", tint: .plain) { actions.removePlanned(sample.id) }
            }
        }
        .padding(.vertical, Look.Space.hair)
        .onAppear { sync() }
        .onChange(of: text) { t in
            let v = t.isEmpty ? nil : Int(t)
            if v != sample.height, t.isEmpty || v != nil { actions.setHeight(sample.id, v) }
        }
        .onChange(of: sample.height) { _ in sync() }
    }

    private func sync() {
        if (text.isEmpty ? nil : Int(text)) != sample.height { text = sample.height.map(String.init) ?? "" }
    }
}

/// The "Before the trip" tab.
struct TripView: View {
    @EnvironmentObject private var store: FieldStore

    var body: some View {
        FieldPage {
            FieldHeader(title: "Before the trip", subtitle: "Can you reach every sample?")
            if store.practice && store.data.plan.isEmpty && store.data.tools.isEmpty {
                FieldButton(title: "Fill with the ladder example", symbol: "square.and.pencil", tint: .hue("second")) {
                    for s in Situations.ladderTrip.plan { store.addPlanned(place: s.place, height: s.height, flow: s.before) }
                    store.addTool(name: "Client's ladder", reach: nil)
                }
            }
            TripPlanner(plan: store.data.plan, tools: store.data.tools, actions: TripActions(
                addPlanned: { store.addPlanned(place: $0, height: $1, flow: FieldStore.plannedFlow) },
                setHeight: { store.setPlannedHeight($0, $1) },
                removePlanned: { store.removePlanned($0) },
                addTool: { store.addTool(name: $0, reach: $1) },
                setReach: { store.setToolReach($0, $1) },
                removeTool: { store.removeTool($0) },
                startPlanned: { store.startPlanned($0) }), practice: store.practice)
        }
    }
}
