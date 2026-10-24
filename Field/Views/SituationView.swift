import SwiftUI

/// "Try a situation": set up a past or typical job, walk through it with the app's reach rules, and answer "Would this have helped?" in four
/// values. The ladder trip is the first example, in stand-in names. Nothing here touches the real trip; the answer is kept on the phone.
struct SituationListView: View {
    @EnvironmentObject private var store: FieldStore

    var body: some View {
        NavigationStack {
            FieldPage {
                FieldHeader(title: "Try a situation", subtitle: "Walk through a job you know, without going out.")
                ForEach(Situations.all) { s in
                    NavigationLink {
                        SituationDetail(situation: s)
                    } label: {
                        VStack(alignment: .leading, spacing: Look.Space.hair) {
                            Text(s.title).ft(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.ink)
                            Text(s.story).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.ink).multilineTextAlignment(.leading)
                            if let a = store.data.answers.first(where: { $0.situation == s.id }) {
                                StatePill(symbol: "checkmark", text: "You said " + FieldWording.fourWords(a.answer))
                            }
                        }
                        .padding(Look.Space.pad).frame(maxWidth: .infinity, alignment: .leading)
                        .bubble("second", radius: Look.Bubble.radiusItem)
                    }
                    .buttonStyle(BubblePressStyle())
                }
                NavigationLink {
                    SituationDetail(situation: Situation(id: "own", title: "Your own situation", story: "Add the samples, their heights and the ladders, then see what the app says.", plan: [], scenarios: []))
                } label: {
                    HStack {
                        Image(systemName: "plus").accessibilityHidden(true)
                        Text("Set up your own").ft(Look.Size.extra, style: .body)
                    }
                    .foregroundStyle(Look.Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl)
                    .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.card))
                }
                .buttonStyle(BubblePressStyle())
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationTitle("Try a situation")
        }
    }
}

struct SituationDetail: View {
    @EnvironmentObject private var store: FieldStore
    let situation: Situation
    @State private var plan: Run
    @State private var tools: [ToolEntry]
    @State private var picked: Four?
    @State private var note = ""
    @State private var saved = false
    @State private var scenarioIndex: Int?

    init(situation: Situation) {
        self.situation = situation
        _plan = State(initialValue: situation.plan)
        _tools = State(initialValue: situation.scenarios.first?.tools ?? [])
    }

    var body: some View {
        FieldPage {
            if store.practice { PracticeLabel() }
            FieldNote(situation.story)
            if !situation.scenarios.isEmpty {
                FieldCard(title: "What happens") {
                    ForEach(Array(situation.scenarios.enumerated()), id: \.offset) { i, sc in
                        FieldButton(title: sc.label, symbol: scenarioIndex == i ? "checkmark.circle" : "circle", tint: scenarioIndex == i ? .hue("accent") : .plain) {
                            tools = sc.tools; scenarioIndex = i
                        }
                        .accessibilityAddTraits(scenarioIndex == i ? .isSelected : [])
                    }
                }
            }
            TripPlanner(plan: plan, tools: tools, actions: actions, practice: true)
            FieldCard(title: "Would this have helped?") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Look.Space.tight)], spacing: Look.Space.tight) {
                    ForEach(Four.allCases, id: \.self) { f in
                        FieldButton(title: FieldWording.fourWords(f), symbol: picked == f ? "checkmark.circle" : nil, tint: picked == f ? .hue("accent") : .plain) { picked = f; saved = false }
                            .accessibilityAddTraits(picked == f ? .isSelected : [])
                    }
                }
                FieldInput(label: "A note (optional)", text: $note, hint: "Leave out names, places and numbers from real jobs.")
                FieldButton(title: saved ? "Kept on this phone" : "Keep my answer", symbol: "checkmark", enabled: picked != nil && !saved) {
                    if let picked { store.answer(situation: situation.id, picked, note: note); saved = true }
                }
            }
        }
        .navigationTitle(situation.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let a = store.data.answers.first(where: { $0.situation == situation.id }) { picked = a.answer; note = a.note; saved = true }
            if situation.scenarios.isEmpty == false && scenarioIndex == nil { scenarioIndex = 0 }
        }
    }

    /// Edits to this copy only.
    private var actions: TripActions {
        TripActions(
            addPlanned: { place, h in plan.insert(Sample(id: freshId(plan), pump: freshId(plan), place: place, start: 0, stop: nil, before: FieldStore.plannedFlow, after: nil, height: h), at: 0) },
            setHeight: { id, h in plan = edit(plan, id) { var s = $0; s.height = h; return s } },
            removePlanned: { id in plan.removeAll { $0.id == id } },
            addTool: { name, r in tools.append(ToolEntry(id: (tools.map(\.id).max() ?? 0) + 1, name: name, reach: r)) },
            setReach: { id, r in if let i = tools.firstIndex(where: { $0.id == id }) { tools[i].reach = r } },
            removeTool: { id in tools.removeAll { $0.id == id } })
    }
}
