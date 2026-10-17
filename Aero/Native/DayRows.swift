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
    /// Things at the same time have no order of their own (Aryn, 2026-10-17: "the choice is on the user"). Organizer gives them as made; the
    /// order drawn is the viewer's: their own order where they gave one (none is kept yet), else their reading direction.
    @Environment(\.layoutDirection) private var direction

    private var actions: PointerActions { .day(store, open: open) }

    var body: some View {
        // the home is today's next and what is left: a quiet row (only where a thing went or was due) is the day view's, as on the web home
        let rows = TieOrder.arrange(day.rows, rightToLeft: direction == .rightToLeft).filter { !(bigNext && Pointer.isQuiet($0.state)) }
        let anytime = TieOrder.arrange(day.anytime, rightToLeft: direction == .rightToLeft).filter { !(bigNext && Pointer.isQuiet($0.state)) }
        let nextID = bigNext ? TieOrder.firstNext(day.simple, rightToLeft: direction == .rightToLeft) : nil
        VStack(alignment: .leading, spacing: Look.Space.gap) {
            SpineColumn(metrics: metrics, spacing: Look.Space.gap) {
                ForEach(rows) { row in
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
                ForEach(anytime) { item in
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
    var nextRowID: String? {
        TieOrder.firstNext(day.simple, rightToLeft: UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft)
            .flatMap { id in day.rows.first { $0.id == id }?.id }
    }
}


/// How a tie is read: Organizer keeps simultaneous things as they were made and says none is first; a left-to-right reader reads them as
/// given, a right-to-left reader the other way round (the same rule as the web page's drawing, aero_web.py `orgTieOrder`).
enum TieOrder {
    /// Each run of consecutive item rows with the same time (no time is one run), reversed for a right-to-left reader.
    static func arrange(_ rows: [DayItem], rightToLeft: Bool) -> [DayItem] {
        guard rightToLeft else { return rows }
        var out: [DayItem] = [], run: [DayItem] = []
        func flush() { out.append(contentsOf: run.reversed()); run = [] }
        for r in rows {
            if let k = r.kind, k != "item" { flush(); out.append(r); continue }
            if let first = run.first, (first.time ?? "") != (r.time ?? "") { flush() }
            run.append(r)
        }
        flush()
        return out
    }

    /// The id drawn as the big Next: the first of the things that are next together, in the viewer's reading direction.
    static func firstNext(_ s: SimpleDay, rightToLeft: Bool) -> String? {
        let ids = (s.nexts ?? []).map(\.id)
        if ids.isEmpty { return s.next?.id }
        return rightToLeft ? ids.last : ids.first
    }
}
