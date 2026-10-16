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

    private var actions: PointerActions { .day(store, open: open) }

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
                                PointerView(pointer: Pointer(row), size: isNext ? .next : .block, actions: actions)
                            }
                            if inlineQuestions, row.question != nil {
                                PointerView(pointer: Pointer(row), size: .question, actions: actions).padding(.leading, metrics.blockX)
                            }
                        }
                        .id(row.id)
                    }
                }
            }
            if !day.anytime.isEmpty {
                Text(day.isToday ? "Today, no set time" : "No set time").fx(Look.Size.question, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    .padding(.top, Look.Space.hair)
                ForEach(day.anytime) { item in
                    VStack(alignment: .leading, spacing: Look.Space.tight) {
                        PointerView(pointer: Pointer(item), size: .block, actions: actions)
                        if inlineQuestions, item.question != nil { PointerView(pointer: Pointer(item), size: .question, actions: actions) }
                    }
                }
            }
        }
        .animation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping), value: day.rows.map(\.id))
    }

    /// The id the home scrolls to so Next is the first thing seen (earlier things sit above it).
    var nextRowID: String? { day.simple.next.flatMap { n in day.rows.first { $0.id == n.id }?.id } }
}

