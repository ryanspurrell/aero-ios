import SwiftUI

/// Organizer's front, drawn natively from the same answer the page draws (organizer_timeline.py; the approved mocks
/// organizer_timeline_2026-10-15.html and organizer_calendar_views_2026-10-15.html). Standard controls, Dynamic Type, VoiceOver labels.
///
/// Progressive disclosure: Year shows shade only, Month coloured dots, Week coloured pills with short names, Day the full timeline; a
/// waiting question is a "?" at every level. One reference date is held across the four; moving between them is a zoom (the day grows
/// out of its week row, month cell or year square: matchedGeometryEffect on the date), by pinch, with the tabs as the tap way.
/// A swipe moves in time, with arrows as the tap way. Today is outlined in red apart from the selected date.
/// A colour is Organizer's (a name, or Colony's calendar colour as hex): looked up as a theme token in the asset catalog
/// ("Organizer/<name>"), never chosen here. The icon and the words always go with it.
struct OrganizerDayScreen: View {
    @StateObject private var store = OrganizerDayStore()
    /// Opens a thing's owner's own screen: Organizer's item, or Colony's event.
    var open: (OpenRef) -> Void = { _ in }
    var openLists: () -> Void = {}
    @Namespace private var zoom
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        VStack(spacing: 0) {
            tabs
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let note = store.answer?.note, !note.isEmpty {
                        Text(note).font(.footnote).foregroundStyle(.secondary)
                    }
                    if let failure = store.failure {
                        Text(failure).font(.callout).foregroundStyle(.secondary)
                    }
                    content
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            // one New… box at the bottom, from the day view only
            if store.answer?.span == .day { NewBox(onAdded: { Task { await store.load() } }) }
        }
        .gesture(
            MagnificationGesture()
                .updating($pinch) { value, state, _ in state = value }
                .onEnded { value in
                    // a step in or out: the ratio is picked, not grounded (as the page's)
                    if value >= 1.3 { Task { await zoomAnimated(1) } } else if value <= 1 / 1.3 { Task { await zoomAnimated(-1) } }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5, abs(value.translation.width) >= 60,
                      let target = value.translation.width < 0 ? nextDate : prevDate else { return }
                Task { await store.move(date: target) }
            }
        )
        .task { await store.load() }
    }

    private var nextDate: String? {
        guard let a = store.answer else { return nil }
        switch a.span {
        case .day: return a.day?.next
        case .week: return a.week?.next
        case .month: return a.month?.next
        case .year: return a.year?.next
        }
    }

    private var prevDate: String? {
        guard let a = store.answer else { return nil }
        switch a.span {
        case .day: return a.day?.prev
        case .week: return a.week?.prev
        case .month: return a.month?.prev
        case .year: return a.year?.prev
        }
    }

    /// The zoom is animated with the system spring that matches Aero's `--ease-spring` (response 0.55, damping fraction 0.825), so the
    /// date's element grows out of, or shrinks into, its place (matchedGeometryEffect).
    private func zoomAnimated(_ step: Int) async {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.825)) { Task { await store.zoom(by: step) } }
    }

    // MARK: tabs

    private var tabs: some View {
        // as simple as it can be: today, and a way to the lists, no calendar tabs to choose among
        HStack(spacing: 0) {
            if store.answer?.mode == .simple {
                tab("Today", selected: true) {}
                tab("Lists", selected: false) { openLists() }
            } else {
                ForEach(CalendarSpan.allCases) { s in
                    tab(s.title, selected: store.span == s) { Task { await switchTo(s) } }
                }
                tab("Lists", selected: false) { openLists() }
            }
        }
        .padding(.horizontal)
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title).font(.body).fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                Rectangle().fill(selected ? Color.accentColor : Color.clear).frame(height: 3).clipShape(Capsule())
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func switchTo(_ s: CalendarSpan) async {
        withAnimation(.spring(response: 0.55, dampingFraction: 0.825)) { Task { await store.move(span: s) } }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let a = store.answer {
            switch a.span {
            case .day:
                if let d = a.day {
                    if a.mode == .simple && d.isToday { SimpleDayView(day: d, store: store, open: open, zoom: zoom) }
                    else { DayTimelineView(day: d, store: store, open: open, zoom: zoom) }
                }
            case .week: if let w = a.week { WeekView(week: w, selected: a.date, store: store, zoom: zoom) }
            case .month: if let m = a.month { MonthView(month: m, selected: a.date, store: store, open: open, zoom: zoom) }
            case .year: if let y = a.year { YearView(year: y, selected: a.date, store: store, zoom: zoom) }
            }
        } else if store.failure == nil {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }
}

// MARK: colour

/// A colour as Organizer sent it: a hex value (Colony's calendar colour) or a name looked up as a theme token in the asset catalog.
func organizerColor(_ value: String?) -> Color {
    guard let value, !value.isEmpty else { return .accentColor }
    if value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) {
        return Color(red: Double((rgb >> 16) & 0xff) / 255, green: Double((rgb >> 8) & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }
    if let ui = UIColor(named: "Organizer/\(value)") { return Color(ui) }
    return .accentColor
}

/// Organizer's symbol names, as SF Symbols (a plain symbol, never colour alone).
func organizerSymbol(_ name: String?) -> String {
    switch name ?? "" {
    case "calendar": return "calendar"
    case "repeat": return "repeat"
    case "cart": return "cart"
    case "check": return "checkmark"
    case "book": return "book"
    case "place": return "mappin"
    case "home": return "house"
    case "heart": return "heart"
    case "money": return "dollarsign.circle"
    case "music": return "music.note"
    case "code": return "chevron.left.forwardslash.chevron.right"
    case "star": return "star"
    case "flag": return "flag"
    case "gift": return "gift"
    case "doc": return "doc"
    case "person": return "person"
    case "food": return "fork.knife"
    case "clock": return "clock"
    default: return "checklist"
    }
}

// MARK: header

struct PeriodHeader: View {
    let title: String
    var subtitle: String? = nil
    let isAway: Bool
    let prev: () -> Void
    let next: () -> Void
    let today: () -> Void

    var body: some View {
        HStack {
            Button(action: prev) { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous")
            Spacer()
            VStack {
                Text(title).font(.title2).bold()
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.center)
            Spacer()
            Button(action: next) { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("Next")
            if isAway { Button("Today", action: today).foregroundStyle(.red) }
        }
    }
}

// MARK: the day, as a timeline

struct DayTimelineView: View {
    let day: DayAnswer
    let store: OrganizerDayStore
    let open: (OpenRef) -> Void
    let zoom: Namespace.ID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PeriodHeader(title: day.label, subtitle: day.dateText, isAway: !day.isToday,
                         prev: { Task { await store.move(date: day.prev) } }, next: { Task { await store.move(date: day.next) } },
                         today: { Task { await store.move(date: "") } })
            ForEach(day.rows) { row in
                switch row.kind {
                case "now": NowLine(text: row.text ?? "")
                case "free": Text(row.text ?? "").font(.subheadline).italic().foregroundStyle(.secondary)
                default: ItemRow(item: row, store: store, open: open)
                }
            }
            if !day.anytime.isEmpty {
                Text(day.isToday ? "Today, no set time" : "No set time").font(.footnote).bold().foregroundStyle(.secondary)
                ForEach(day.anytime) { ItemRow(item: $0, store: store, open: open) }
            }
        }
        .matchedGeometryEffect(id: day.date, in: zoom)
    }
}

struct NowLine: View {
    let text: String
    var body: some View {
        HStack {
            Text("Now").font(.caption).bold().padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red, in: Capsule()).foregroundStyle(.white)
            Rectangle().fill(Color.red).frame(height: 2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Now")
    }
}

struct ItemRow: View {
    let item: DayItem
    let store: OrganizerDayStore
    let open: (OpenRef) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.timeText ?? "").font(.footnote).bold().frame(width: 62, alignment: .trailing).foregroundStyle(.secondary)
            Circle().fill(item.state == "done" ? Color.primary.opacity(0.2) : organizerColor(item.color)).frame(width: 10, height: 10).padding(.top, 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Button { if let o = item.open { open(o) } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: item.state == "done" ? "checkmark" : organizerSymbol(item.icon))
                            .frame(width: 28)
                        VStack(alignment: .leading) {
                            Text(item.title ?? "").font(.headline).strikethrough(item.state == "done")
                            if let meta { Text(meta).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .bubble(item.color, done: item.state == "done")
                }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel(label)
                if let q = item.question { QuestionCard(question: q, store: store, large: false) }
            }
        }
    }

    private var meta: String? {
        if item.state == "done" { return "Done" + (item.doneAtText.map { " at " + $0 } ?? "") }
        if item.state == "overdue" { return "From before" }
        if let until = item.until { return until }
        if let end = item.endText, !end.isEmpty { return "Until " + end }
        if item.late == true { return "Not done" }
        return item.isRepeat == true ? "Repeats" : nil
    }

    private var label: String {
        [item.title, item.timeText, meta, item.source == "colony" ? "from the calendar" : nil].compactMap { $0 }.joined(separator: ", ")
    }
}

/// A question that is still open, in place on its thing. The answer is recorded where it was given: the chosen choice is marked with a
/// check and its words, the others stay tappable to change it, and it stays on screen until a later load (people tap by accident and want
/// to fix it in the same place).
struct QuestionCard: View {
    let question: Question
    let store: OrganizerDayStore
    let large: Bool
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question.capture).font(large ? .title3 : .subheadline).bold()
            Text(question.ask.isEmpty ? "Which did you mean?" : question.ask).font(large ? .body : .subheadline)
            // wide choices stack when the text is large (Dynamic Type)
            ViewThatFits {
                HStack { choices }
                VStack { choices }
            }
            if let chosen, let c = question.choices.first(where: { $0.index == chosen }) {
                Text("Recorded: \(c.label). Tap another to change it.").font(.footnote).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4])).foregroundStyle(.secondary))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Question: \(question.capture)")
    }

    @ViewBuilder private var choices: some View {
        ForEach(question.choices) { c in
            Button {
                Task { if await store.choose(c) { chosen = c.index } }
            } label: {
                HStack(spacing: 4) {
                    if chosen == c.index { Image(systemName: "checkmark") }
                    Text(c.label).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: large ? 56 : 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(chosen == c.index ? .primary : .accentColor)
            .accessibilityAddTraits(chosen == c.index ? .isSelected : [])
        }
    }
}

// MARK: the day, as simple as it can be

struct SimpleDayView: View {
    let day: DayAnswer
    let store: OrganizerDayStore
    let open: (OpenRef) -> Void
    let zoom: Namespace.ID
    @State private var done = false
    @State private var asked = false

    var body: some View {
        let s = day.simple
        VStack(alignment: .leading, spacing: 16) {
            Text(s.greeting).font(.largeTitle).bold()
            Text(s.clock).font(.title3).foregroundStyle(.secondary)
            if let q = (day.rows + day.anytime).compactMap({ $0.question }).first { QuestionCard(question: q, store: store, large: true) }
            if let n = s.next { nextCard(n) } else { Text(s.none.isEmpty ? "Nothing else is planned for today." : s.none).font(.title3) }
            if !s.behind.isEmpty { listCard("Not done yet", s.behind) }
            if !s.later.isEmpty { listCard("Later", s.later) }
            ForEach(s.did) { line in Label(line.text ?? "", systemImage: "checkmark").font(.body) }
            if !store.helpers.isEmpty { helpButton }
        }
        .matchedGeometryEffect(id: day.date, in: zoom)
    }

    private func nextCard(_ n: SimpleNext) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("NEXT").font(.subheadline).bold().foregroundStyle(.secondary)
            Label(n.title, systemImage: organizerSymbol(n.icon)).font(.largeTitle).bold()
            Text(n.line).font(.title3)
            Button {
                if n.source == "colony" { open(n.open); return }
                Task { if await store.setDone(n.open.id, done: !done) { done.toggle() } }
            } label: {
                // recorded where it was pressed, and taken back there
                Text(n.source == "colony" ? "Open" : done ? "Done. Tap to undo" : n.button).font(.title2).bold()
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent).tint(.primary)
        }
        .padding(20)
        .bubble(n.color, radius: 28, lift: 7)
    }

    private func listCard(_ title: String, _ lines: [SimpleLine]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            ForEach(lines) { Text(($0.title ?? "") + ($0.timeText.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")).font(.title3).bold() }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paleBlock(radius: 24)
    }

    /// "Ask for help" goes to the person's helper as their Fingus, when they let one; hidden otherwise.
    private var helpButton: some View {
        Button {
            Task { if await store.askForHelp() { asked = true } }
        } label: {
            Text(asked ? "\(store.helpers.joined(separator: " and ")) will see that you asked." : "Ask for help")
                .font(.title3).frame(maxWidth: .infinity, minHeight: 60)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: week, month, year

struct WeekView: View {
    let week: WeekAnswer
    let selected: String
    let store: OrganizerDayStore
    let zoom: Namespace.ID

    var body: some View {
        VStack(spacing: 8) {
            PeriodHeader(title: week.text, isAway: !week.days.contains { $0.today },
                         prev: { Task { await store.move(date: week.prev) } }, next: { Task { await store.move(date: week.next) } },
                         today: { Task { await store.move(date: "") } })
            ForEach(week.days) { d in
                Button { Task { await store.move(span: .day, date: d.date) } } label: {
                    HStack(alignment: .top, spacing: 10) {
                        VStack { Text("\(d.day)").font(.title3).bold(); Text(d.weekday).font(.caption) }.frame(width: 48)
                        if d.free { Text("Free").italic().foregroundStyle(.secondary) }
                        FlowPills(pills: d.pills)
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paleBlock(radius: 18)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.red, lineWidth: d.today ? 3 : 0))
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.accentColor, lineWidth: d.date == selected && !d.today ? 3 : 0))
                }
                .buttonStyle(BubblePressStyle())
                .matchedGeometryEffect(id: d.date, in: zoom)
                .accessibilityLabel("\(d.weekday) \(d.day)\(d.today ? ", today" : ""), \(d.pills.count) things\(d.pills.contains { $0.question } ? ", a question is waiting" : "")")
            }
        }
    }
}

/// Coloured pills in time order, wrapping; each with its words (colour is never the only signal).
struct FlowPills: View {
    let pills: [Pill]
    var body: some View {
        // a plain wrapping layout from a lazy grid: pills of any width flow to the next line
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(pills) { p in
                HStack(spacing: 4) {
                    Text((p.timeText.isEmpty ? "" : p.timeText + " ") + p.title).lineLimit(1).font(.footnote).bold()
                    if p.question { Text("?").font(.caption2).bold().padding(3).background(Circle().fill(Color.primary)).foregroundStyle(.background) }
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .bubble(p.color, radius: 14, lift: 2)
            }
        }
    }
}

struct MonthView: View {
    let month: MonthAnswer
    let selected: String
    let store: OrganizerDayStore
    let open: (OpenRef) -> Void
    let zoom: Namespace.ID
    @State private var picked: String?

    var body: some View {
        let cur = picked ?? selected
        VStack(spacing: 8) {
            PeriodHeader(title: month.text, isAway: !month.cells.contains { $0.today && $0.inMonth },
                         prev: { Task { await store.move(date: month.prev) } }, next: { Task { await store.move(date: month.next) } },
                         today: { Task { await store.move(date: "") } })
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(Array(month.weekdays.enumerated()), id: \.offset) { Text($0.element).font(.caption).bold().foregroundStyle(.secondary) }
                ForEach(month.cells) { c in
                    Button {
                        // a first tap shows the day's things below; a second opens the day
                        if cur == c.date { Task { await store.move(span: .day, date: c.date) } } else { picked = c.date }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            Text("\(c.day)").font(.footnote).bold().padding(5).foregroundStyle(c.inMonth ? Color.primary : Color.secondary)
                            HStack(spacing: 2) {
                                ForEach(Array(c.colors.prefix(4).enumerated()), id: \.offset) { Circle().fill(organizerColor($0.element)).frame(width: 7, height: 7) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(5)
                            if c.question { Text("?").font(.caption2).bold().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(4) }
                        }
                        .aspectRatio(1, contentMode: .fit)                  // square days
                        .paleBlock(radius: 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.red, lineWidth: c.today ? 3 : 0))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: c.date == cur && !c.today ? 3 : 0))
                    }
                    .buttonStyle(BubblePressStyle())
                    .matchedGeometryEffect(id: c.date, in: zoom)
                    .accessibilityLabel("\(c.day), \(c.count) things\(c.today ? ", today" : "")\(c.question ? ", a question is waiting" : "")")
                }
            }
            if let c = month.cells.first(where: { $0.date == cur }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(c.date).font(.footnote).bold().foregroundStyle(.secondary)
                    if c.pills.isEmpty { Text("Free").italic().foregroundStyle(.secondary) }
                    FlowPills(pills: c.pills)
                    Button("Open the day") { Task { await store.move(span: .day, date: c.date) } }.buttonStyle(.borderedProminent)
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .paleBlock(radius: 18)
            }
        }
    }
}

struct YearView: View {
    let year: YearAnswer
    let selected: String
    let store: OrganizerDayStore
    let zoom: Namespace.ID

    var body: some View {
        VStack(spacing: 8) {
            PeriodHeader(title: year.text, isAway: !year.months.contains { $0.now },
                         prev: { Task { await store.move(date: year.prev) } }, next: { Task { await store.move(date: year.next) } },
                         today: { Task { await store.move(date: "") } })
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(year.months) { m in
                    Button {
                        let inside = m.days.contains { $0.date == selected }
                        Task { await store.move(span: .month, date: inside ? selected : m.month) }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(m.name).font(.subheadline).bold(); if m.days.contains(where: { $0.question }) { Text("?").font(.caption).bold() } }
                            // shade only: a square a day, darker is fuller
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                                ForEach(0..<m.offset, id: \.self) { _ in Color.clear.frame(height: 8) }
                                ForEach(m.days) { d in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(d.today ? Color.red : Color.accentColor.opacity([0.12, 0.4, 0.7, 1][min(d.level, 3)]))
                                        .frame(height: 8)
                                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: d.date == selected ? 1.5 : 0))
                                        .matchedGeometryEffect(id: d.date, in: zoom)
                                }
                            }
                        }
                        .padding(8)
                        .paleBlock(radius: 14)
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.red, lineWidth: m.now ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.name), \(m.days.filter { $0.count > 0 }.count) days with things\(m.days.contains { $0.question } ? ", a question is waiting" : "")")
                }
            }
            Text(year.why.prefix(1).uppercased() + year.why.dropFirst() + ".").font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: the one box

/// The one box at the bottom: Organizer's quick add reads the words (`quickadd`); "or ask" only when an assistant is set up
/// (the app asks Aero for that the way the page does; none is set up here until the app has the assistant).
struct NewBox: View {
    var assistantSetUp = false
    var onAdded: () -> Void = {}
    @State private var text = ""
    @State private var asking: QuickAddOutcome?
    @State private var failure: String?
    private let backend = OrganizerBackends.current()

    var body: some View {
        VStack(spacing: 4) {
            if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            HStack {
                Image(systemName: "plus")
                TextField(assistantSetUp ? "Task, reminder, note, or ask…" : "Task, reminder, or note…", text: $text)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("quick-add-field")
                // the microphone: dictation through the keyboard's own key until the app records for this box
            }
            .padding(14)
            .background(.regularMaterial, in: Capsule())
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
        .sheet(item: Binding<AskItem?>(get: { asking.flatMap { $0.question == nil ? nil : AskItem(outcome: $0) } }, set: { if $0 == nil { asking = nil } })) { item in
            QuickAddAsk(outcome: item.outcome, backend: backend) { asking = nil; onAdded() }
                .presentationDetents([.medium, .large])
        }
        .task { await DemoMode.runQuickAddIfAsked(backend: backend) { outcome in asking = outcome; onAdded() } }
    }

    private func submit() {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        text = ""
        Task {
            do {
                let outcome = try await backend.quickAdd(line)
                failure = nil
                if outcome.question != nil { asking = outcome }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "That was not added. Try again."
            }
            onAdded()
        }
    }
}

struct AskItem: Identifiable {
    var outcome: QuickAddOutcome
    var id: String { outcome.question?.id ?? outcome.typed }
}

/// The question a typed line raised, as the web asks it: only the readings still live, the likeliest first (marked only when it really
/// is likelier), then "Something else"; the words as typed are shown beneath. A choice is the same `update` the day's own question sends.
struct QuickAddAsk: View {
    let outcome: QuickAddOutcome
    let backend: OrganizerBackend
    var done: () -> Void
    @State private var failure: String?

    var body: some View {
        if let q = outcome.question {
            VStack(alignment: .leading, spacing: 12) {
                Text(q.ask.isEmpty ? "Which did you mean?" : q.ask).font(.headline)
                ForEach(q.choices) { c in
                    Button {
                        Task { do { try await backend.apply(c.answer); done() } catch { failure = error.localizedDescription } }
                    } label: {
                        HStack {
                            Text(c.label).multilineTextAlignment(.leading)
                            Spacer()
                            if outcome.likeliest == c.index { Text("Likeliest").font(.footnote).foregroundStyle(.secondary) }
                        }
                        .padding(14).frame(maxWidth: .infinity, minHeight: 44).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    Task { do { try await backend.keepPlain(q); done() } catch { failure = error.localizedDescription } }
                } label: {
                    Text("Something else").padding(14).frame(maxWidth: .infinity, minHeight: 44).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                Text("What you typed").font(.footnote).foregroundStyle(.secondary)
                Text(outcome.typed).font(.callout)
                if let failure { Text(failure).font(.footnote).foregroundStyle(.red) }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }
}
