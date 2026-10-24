import SwiftUI

/// Settings: the practice copy, who tickets are addressed to, the numbers and where each comes from, and erasing everything.
struct SettingsView: View {
    @EnvironmentObject private var store: FieldStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmErase = false
    @State private var owner = ""

    var body: some View {
        SheetFrame(title: "Settings") {
            FieldCard(title: "Practice copy") {
                Toggle("Practice copy", isOn: Binding(get: { store.practice }, set: { store.setPractice($0) }))
                    .ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.fg)
                FieldNote(store.practice
                          ? "Stand-in names fill in for you, so nothing real has to be typed. Use it beside your paper sheet."
                          : "Names you type are kept on this phone only.")
            }
            FieldCard(title: "Tickets go to") {
                FieldInput(label: "Owner of this install", text: $owner)
                FieldButton(title: "Save", symbol: "checkmark", tint: .plain, enabled: !owner.trimmingCharacters(in: .whitespaces).isEmpty) { store.setOwner(owner) }
            }
            NumbersCard()
            FieldCard(title: "What stays on this phone") {
                FieldNote("Everything. This app has no way to send anything: no network, no location. Sharing a sheet or a ticket happens only when you tap share.")
                FieldButton(title: "Erase everything on this phone", symbol: "trash", tint: .hue("red")) { confirmErase = true }
            }
        }
        .onAppear { owner = store.data.owner }
        .confirmationDialog("Erase every pump, trip, handover and ticket on this phone?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase everything", role: .destructive) { store.eraseEverything(); dismiss() }
            Button("Keep it", role: .cancel) {}
        }
    }
}

/// Every number the app uses, with where it comes from. One is marked picked, not grounded (FieldSample.lean, `method7400`).
struct NumbersCard: View {
    @EnvironmentObject private var store: FieldStore
    var body: some View {
        let m = store.method
        FieldCard(title: "About the numbers") {
            row("Flow band \(m.lo.text()) to \(m.hi.text()) L/min", "From the method (NIOSH 7400), as read in our notes.")
            row("Needs \(FieldWording.litres(m.minVol))", "From the same method.")
            row("Flow may change by \(m.tol.text()) L/min between before and after", "Picked, not grounded. The method gives no before-and-after rule in our notes.")
            row("Volume is the mean of the two flows times the minutes", "The method's usual calculation. A convention, not a measurement.")
            row("Each flow reading may be off by 5 percent", "Picked from a pump study in our notes, not from your pump. The bars on volume and flow use it.")
            FieldNote("A first try from public records, to be corrected by the person who does the work. Nothing here says a lab will accept a sample marked Counts.")
        }
    }

    private func row(_ title: String, _ why: String) -> some View {
        VStack(alignment: .leading, spacing: Look.Space.hairline) {
            Text(title).ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.fg)
            Text(why).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        }
        .accessibilityElement(children: .combine)
    }
}
