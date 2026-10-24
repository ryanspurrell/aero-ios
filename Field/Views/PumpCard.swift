import SwiftUI

/// One card per pump (Part D: several pumps in one run, each independent: `add_independent`, `edit_independent`, `stop_independent`). Shows the place,
/// the sample id, a live timer to the stop time (Part E: `stopDue`), the flows before and after, and the sample's state with its reason
/// (Part C: `state`, `toFour`).
struct PumpCard: View {
    @EnvironmentObject private var store: FieldStore
    let sample: Sample
    var onEdit: () -> Void
    var onAfter: () -> Void

    var body: some View {
        let w = FieldWording.words(store.method, sample)
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            VStack(alignment: .leading, spacing: Look.Space.tight) {
                Text("Pump \(sample.pump), sample \(sample.id)").ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.label)
                Text(sample.place.isEmpty ? "No place yet" : sample.place).ft(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.ink)
                StatePill(symbol: w.symbol, text: w.headline)
                Text(w.detail).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.ink).fixedSize(horizontal: false, vertical: true)
                StopTimer(sample: sample, minVol: store.method.minVol)
                Text(flows).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.label)
            }
            .accessibilityElement(children: .combine)
            FieldButtonRow {
                if sample.stop == nil {
                    FieldButton(title: "Stop pump", symbol: "stop.circle", tint: .plain) { store.stop(sample.id) }
                } else if sample.after == nil {
                    FieldButton(title: "Add flow after", symbol: "plus.circle", tint: .plain, action: onAfter)
                }
                FieldButton(title: "Edit", symbol: "pencil", tint: .plain, action: onEdit)
            }
        }
        .padding(Look.Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubble(w.hue, radius: Look.Bubble.radiusItem)
    }

    private var flows: String {
        "Flow before " + FieldWording.flow(sample.before) + ", after " + (sample.after.map(FieldWording.flow) ?? "not measured")
    }
}

/// The live timer. Running with a planned flow: counts down to `stopDue`. Stopped: says when it stopped. The screen reader hears the minute-level
/// line and is told the line updates; it is not read every second.
struct StopTimer: View {
    let sample: Sample
    let minVol: Rat

    var body: some View {
        if let e = sample.stop {
            Label("Stopped at " + FieldClock.time(e) + " after " + FieldClock.span(monus(e, sample.start)), systemImage: "stop.circle")
                .ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.ink)
        } else if Rat(0) < sample.before {
            let due = stopDue(sample.start, minVol, sample.before)
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = Int((Double(due) * 60 - ctx.date.timeIntervalSince1970).rounded(.up))
                let minutes = (left + 59) / 60
                VStack(alignment: .leading, spacing: 0) {
                    Text(left > 0 ? "Stop in " + Self.clock(left) : "Stop time reached")
                        .ft(Look.Size.nextName, style: .title2).monospacedDigit().foregroundStyle(Look.Palette.ink)
                    Text("Stop at " + FieldClock.time(due) + " for " + FieldWording.litres(minVol))
                        .ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.label)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(left > 0 ? "Stop at \(FieldClock.time(due)), \(FieldClock.span(minutes)) left" : "Stop time reached, \(FieldClock.time(due))")
                .accessibilityAddTraits(.updatesFrequently)
            }
        } else {
            Label("Add a flow to see the stop time", systemImage: "timer").ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.ink)
        }
    }

    /// 1:12:05 or 12:05
    static func clock(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}
