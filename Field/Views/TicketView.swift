import SwiftUI

/// "Report something": a ticket for the owner of this install. The screen shows exactly what would be sent, and it is kept on this phone; the app
/// has no way to send it. A ticket carries the screen, the step and the shape of what happened, never the pumps, places, flows, times or names.
/// The rule that a ticket goes up only one level, and only as written at its own level, has no Lean counterpart yet (see the ideas entry,
/// "Added 4:24 pm"); the app keeps tickets only on the device, which is the one case that rule allows.
struct TicketView: View {
    @EnvironmentObject private var store: FieldStore
    @State private var kind: TicketKind = .edgeCase
    @State private var screen = "Board"
    @State private var step = ""
    @State private var what = ""
    @State private var justKept = false

    static let screens = ["Board", "Before the trip", "Chain of custody", "Try a situation", "Settings", "Something else"]

    private var draft: Ticket {
        Ticket(id: 0, kind: kind, screen: screen, step: step, what: what, to: store.data.owner, practice: store.practice, made: store.now)
    }

    var body: some View {
        FieldPage {
            FieldHeader(title: "Report something", subtitle: "Goes to \(store.data.owner). Kept on this phone.")
            FieldCard(title: "What kind") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: Look.Space.tight)], spacing: Look.Space.tight) {
                    ForEach(TicketKind.allCases, id: \.self) { k in
                        FieldButton(title: FieldWording.kind(k), symbol: kind == k ? "checkmark.circle" : nil, tint: kind == k ? .hue("accent") : .plain) { kind = k; justKept = false }
                            .accessibilityAddTraits(kind == k ? .isSelected : [])
                    }
                }
                HStack {
                    Text("Which screen").ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.fg)
                    Spacer(minLength: Look.Space.tight)
                    Picker("Which screen", selection: $screen) { ForEach(Self.screens, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                }
                FieldInput(label: "Which step", text: $step, prompt: "For example after tapping Stop pump")
                FieldInput(label: "What happened, in a few words", text: $what, hint: "Leave out names, places and numbers from real jobs.")
            }
            FieldCard(title: "What would be sent") {
                ForEach(Array(TicketText.lines(draft).enumerated()), id: \.offset) { _, line in
                    Text(line).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.fg).fixedSize(horizontal: false, vertical: true)
                }
                FieldNote("Not included: your pumps, places, flows, times, names, photos or location.")
                FieldButton(title: justKept ? "Kept on this phone" : "Keep on this phone", symbol: "tray.and.arrow.down", enabled: !what.trimmingCharacters(in: .whitespaces).isEmpty && !justKept) {
                    store.keepTicket(kind: kind, screen: screen, step: step, what: what)
                    what = ""; step = ""; justKept = true
                }
                FieldNote("Nothing is sent from here. It reaches the owner only if you share it yourself.")
            }
            if !store.data.tickets.isEmpty {
                FieldCard(title: "Kept on this phone") {
                    ForEach(store.data.tickets.reversed()) { t in
                        VStack(alignment: .leading, spacing: Look.Space.hair) {
                            Text(FieldWording.kind(t.kind) + ", " + t.screen).ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.fg)
                            Text(t.what).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.soft)
                            FieldButtonRow {
                                ShareLink(item: TicketText.lines(t).joined(separator: "\n")) {
                                    Label("Share", systemImage: "square.and.arrow.up").ft(Look.Size.extra, style: .body)
                                        .foregroundStyle(Look.Palette.ink).frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl)
                                        .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.accent))
                                }
                                FieldButton(title: "Remove", symbol: "trash", tint: .plain) { store.removeTicket(t.id) }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Exactly the lines of a ticket: the same text is shown, kept and (if the person shares it) sent.
enum TicketText {
    static func lines(_ t: Ticket) -> [String] {
        [
            "To: " + t.to,
            "Kind: " + FieldWording.kind(t.kind),
            "Screen: " + t.screen,
            "Step: " + (t.step.isEmpty ? "not said" : t.step),
            "What happened: " + (t.what.isEmpty ? "not said" : t.what),
            "Practice copy: " + (t.practice ? "yes" : "no"),
        ]
    }
}
