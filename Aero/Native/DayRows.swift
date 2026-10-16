import SwiftUI

/// The day's things down the time spine, the same on the home and in the day view. Each timed thing is its own block at its own time with its
/// own knot; the red Now line sits where now falls; "Free until ..." comes between as the web says it (the rows are organizer_timeline.py's,
/// the same Python that arranges the web's day, so the rule is not written again here); things with no time are set apart beneath under their
/// own heading; what is done is faded.
struct DayRows: View {
    let day: DayAnswer
    let metrics: SpineMetrics
    /// The home: the next thing is the big block in its own place on the spine.
    var bigNext = false
    /// The day view puts a question under its own thing; the home draws it once, under the day.
    var inlineQuestions = true
    let store: OrganizerDayStore
    let open: (OpenRef) -> Void

    var body: some View {
        let nextID = bigNext ? day.simple.next?.id : nil
        VStack(alignment: .leading, spacing: Look.Space.gap) {
            SpineColumn(metrics: metrics, spacing: Look.Space.gap) {
                ForEach(day.rows) { row in
                    switch row.kind {
                    case "now": NowRow(metrics: metrics, timeText: row.timeText ?? "")
                    case "free": FreeRow(metrics: metrics, text: row.text ?? "")
                    default:
                        let isNext = row.id == nextID
                        VStack(alignment: .leading, spacing: Look.Space.tight) {
                            SpineRow(metrics: metrics, timeText: row.timeText ?? "", knot: Fingus.hue(row.color).base, centered: !isNext) {
                                if isNext { NextBlock(item: row) { if let o = row.open { open(o) } } }
                                else { ItemBlock(item: row) { if let o = row.open { open(o) } } }
                            }
                            if inlineQuestions, let q = row.question {
                                QuestionInPlace(question: q, store: store).padding(.leading, metrics.blockX)
                            }
                        }
                        .id(row.id)
                    }
                }
            }
            if !day.anytime.isEmpty {
                Text(day.isToday ? "Today, no set time" : "No set time").fx(Look.Size.question, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    .padding(.top, 6)
                ForEach(day.anytime) { item in
                    VStack(alignment: .leading, spacing: Look.Space.tight) {
                        ItemBlock(item: item) { if let o = item.open { open(o) } }
                        if inlineQuestions, let q = item.question { QuestionInPlace(question: q, store: store) }
                    }
                }
            }
        }
        .animation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping), value: day.rows.map(\.id))
    }

    /// The id the home scrolls to so Next is the first thing seen (earlier things sit above it).
    var nextRowID: String? { day.simple.next.flatMap { n in day.rows.first { $0.id == n.id }?.id } }
}

/// The home's big block: Next, its name, how long until it (as the day says it).
struct NextBlock: View {
    let item: DayItem
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Look.Space.hair / 2) {
                Text("NEXT").fx(Look.Size.nextLabel, style: .caption1).tracking(1).foregroundStyle(Look.Palette.label)
                Text(item.title ?? "").fx(Look.Size.nextName, style: .title1).foregroundStyle(Look.Palette.ink).padding(.top, 4)
                if let line = item.until ?? item.endText.map({ "Until " + $0 }) {
                    Text(line).fx(Look.Size.nextMeta, style: .subheadline).foregroundStyle(Look.Palette.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Look.Space.gutter).padding(.vertical, 18)
            .background {
                let c = Fingus.hue(item.color)
                ZStack {
                    RoundedRectangle(cornerRadius: Look.Bubble.radiusNext, style: .continuous)
                        .fill(LinearGradient(colors: [c.light, c.base], startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)))
                        .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowNext.alpha), radius: Look.Bubble.shadowNext.blur / 2, x: 0, y: Look.Bubble.shadowNext.y)
                }
            }
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel("Next: \(item.title ?? ""), \(item.until ?? ""). Opens your day.")
    }
}
