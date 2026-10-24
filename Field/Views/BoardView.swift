import SwiftUI

/// The board: one card per pump, newest first. "Add a pump" sits at the bottom of the screen, where a thumb reaches it.
struct BoardView: View {
    enum Sheet: Identifiable, Hashable {
        case add, edit(Int), after(Int), settings
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let i): return "edit\(i)"
            case .after(let i): return "after\(i)"
            case .settings: return "settings"
            }
        }
    }

    @EnvironmentObject private var store: FieldStore
    @State private var sheet: Sheet?

    init(initialSheet: Sheet? = nil) { _sheet = State(initialValue: initialSheet) }

    var body: some View {
        NavigationStack {
            FieldPage {
                HStack(alignment: .top) {
                    FieldHeader(title: "Board", subtitle: store.data.run.isEmpty ? nil : "\(store.data.run.count) \(store.data.run.count == 1 ? "pump" : "pumps")")
                    Button { sheet = .settings } label: {
                        Image(systemName: "gearshape").font(.title3).frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                    }
                    .foregroundStyle(Look.Palette.fg)
                    .accessibilityLabel("Settings")
                }
                if store.data.run.isEmpty {
                    FieldCard(title: "No pumps yet") {
                        FieldNote("Add a pump when you start one. Each pump gets its own card and its own timer.")
                        if store.practice {
                            FieldButton(title: "Fill with a practice example", symbol: "square.and.pencil", tint: .hue("second")) { store.loadExample() }
                        }
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Look.Space.gap, alignment: .top)], spacing: Look.Space.gap) {
                        ForEach(store.data.run) { s in
                            PumpCard(sample: s, onEdit: { sheet = .edit(s.id) }, onAfter: { sheet = .after(s.id) })
                        }
                    }
                }
                Color.clear.frame(height: Look.Space.sizeControl + Look.Space.gap)
            }
            .safeAreaInset(edge: .bottom) {
                FieldButton(title: "Add a pump", symbol: "plus") { sheet = .add }
                    .padding(.horizontal, Look.Space.gutter).padding(.bottom, Look.Space.tight)
                    .frame(maxWidth: 820)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .add: PumpForm(editing: nil)
            case .edit(let id):
                if let s = store.data.run.first(where: { $0.id == id }) { PumpForm(editing: s) }
            case .after(let id):
                if let s = store.data.run.first(where: { $0.id == id }) { FlowAfterForm(sample: s) }
            case .settings: SettingsView()
            }
        }
    }
}

/// Wraps a sheet's content with a title and a Close key at the top, and the ground behind.
struct SheetFrame<Content: View>: View {
    let title: String
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder var content: Content
    var body: some View {
        NavigationStack {
            FieldPage { content }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                }
        }
    }
}

/// Add a pump, or edit one. Adding starts the pump now with the flow given; the stop time shown is `stopDue` at that flow. Editing changes any field
/// of the sample except its id (`edit_independent`).
struct PumpForm: View {
    @EnvironmentObject private var store: FieldStore
    @Environment(\.dismiss) private var dismiss
    let editing: Sample?

    @State private var place = ""
    @State private var pump = ""
    @State private var before = "2"
    @State private var after = ""
    @State private var height = ""
    @State private var start = Date()
    @State private var stopped = false
    @State private var stop = Date()
    @State private var loaded = false

    private var flow: Rat? { Rat.parse(before) }
    private var afterFlow: Rat? { after.isEmpty ? nil : Rat.parse(after) }
    private var heightValue: Int? { height.isEmpty ? nil : Int(height) }
    private var valid: Bool {
        flow != nil && Int(pump) != nil && (after.isEmpty || afterFlow != nil) && (height.isEmpty || heightValue != nil)
    }

    var body: some View {
        SheetFrame(title: editing == nil ? "Add a pump" : "Edit pump") {
            FieldInput(label: "Place", text: $place, prompt: store.practice ? "For example Building 1, Room 101" : "Where the pump is")
            if store.practice {
                FieldButton(title: "Use a stand-in name", symbol: "textformat", tint: .hue("second")) {
                    place = StandIn.place(editing?.pump ?? Int(pump) ?? 1)
                }
            }
            FieldInput(label: "Pump number", text: $pump, keyboard: .numberPad)
            FieldInput(label: "Flow before, L/min", text: $before, keyboard: .decimalPad,
                       hint: flow == nil ? "A number like 2 or 2.5." : stopHint)
            if editing != nil {
                DatePicker("Started", selection: $start).ft(Look.Size.calm, style: .body)
                Toggle("Stopped", isOn: $stopped).ft(Look.Size.calm, style: .body)
                if stopped { DatePicker("Stopped at", selection: $stop).ft(Look.Size.calm, style: .body) }
                FieldInput(label: "Flow after, L/min", text: $after, keyboard: .decimalPad, hint: after.isEmpty || afterFlow != nil ? nil : "A number like 2 or 2.5.")
            }
            FieldInput(label: "Height, cm (optional)", text: $height, keyboard: .numberPad)
            FieldButton(title: editing == nil ? "Start pump" : "Save changes", symbol: "checkmark", enabled: valid, action: save)
            if let editing {
                FieldButton(title: "Remove this pump", symbol: "trash", tint: .hue("red")) {
                    store.removePump(editing.id)
                    dismiss()
                }
            }
        }
        .onAppear(perform: load)
    }

    /// "At this flow it needs 3 h 20 min. Stop at 4:10 PM." (`dueRun`, `stopDue`)
    private var stopHint: String? {
        guard let f = flow, Rat(0) < f else { return nil }
        let mins = dueRun(store.method.minVol, f)
        return "At this flow it needs \(FieldClock.span(mins)) to reach \(FieldWording.litres(store.method.minVol))."
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let s = editing {
            place = s.place; pump = String(s.pump); before = s.before.text(); after = s.after?.text() ?? ""
            height = s.height.map(String.init) ?? ""
            start = FieldClock.date(s.start); stopped = s.stop != nil; stop = FieldClock.date(s.stop ?? store.now)
        } else {
            pump = String(store.nextPumpNumber())
            if store.practice { place = StandIn.place(store.nextPumpNumber()) }
        }
    }

    private func save() {
        guard let f = flow, let p = Int(pump) else { return }
        if var s = editing {
            s.place = place; s.pump = p; s.before = f; s.after = afterFlow; s.height = heightValue
            s.start = FieldClock.minutes(start); s.stop = stopped ? FieldClock.minutes(stop) : nil
            store.update(s)
        } else {
            store.addPump(place: place, pump: p, before: f, height: heightValue)
        }
        dismiss()
    }
}

/// The flow measured after the run. Until it is added the sample waits (`afterMissing_not_yes`).
struct FlowAfterForm: View {
    @EnvironmentObject private var store: FieldStore
    @Environment(\.dismiss) private var dismiss
    let sample: Sample
    @State private var flow = ""

    var body: some View {
        SheetFrame(title: "Flow after") {
            FieldNote("\(sample.place.isEmpty ? "Pump \(sample.pump)" : sample.place). Flow before was \(FieldWording.flow(sample.before)).")
            FieldInput(label: "Flow after, L/min", text: $flow, keyboard: .decimalPad, hint: flow.isEmpty || Rat.parse(flow) != nil ? nil : "A number like 2 or 2.5.")
            FieldButton(title: "Add flow after", symbol: "checkmark", enabled: Rat.parse(flow) != nil) {
                if let r = Rat.parse(flow) { store.setAfter(sample.id, r) }
                dismiss()
            }
        }
    }
}
