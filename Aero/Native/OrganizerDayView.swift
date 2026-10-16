import SwiftUI

/// Organizer's front, drawn natively from the same answer the page draws (organizer_timeline.py), in the approved mocks: the day as the B1
/// time spine (organizer_item_bubbly, organizer_timeline), the week, month and year as organizer_calendar_views draws them, with Day, Week,
/// Month and Year as underline tabs, arrows and the held date. Type, colour, radii and shadows are tokens (Tokens.swift); the page ground is
/// Fingus's, and nothing uses the system's navigation bar or list styles.
///
/// Progressive disclosure: Year shows shade only, Month coloured dots, Week coloured pills with short names, Day the full timeline; a waiting
/// question is a "?" at every level. One reference date is held across the four; moving between them is a zoom (the day grows out of its week
/// row, month cell or year square: matchedGeometryEffect on the date), by pinch, with the tabs as the tap way. A swipe moves in time, with
/// arrows as the tap way. Today is outlined in the Now red apart from the selected date.
struct OrganizerDayScreen: View {
    @StateObject private var store = OrganizerDayStore()
    /// Opens a thing's owner's own screen: Organizer's item, or Colony's event.
    var open: (OpenRef) -> Void = { _ in }
    var openLists: () -> Void = {}
    var back: () -> Void = {}
    @Namespace private var zoom
    @GestureState private var pinch: CGFloat = 1

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                backRow
                tabs.padding(.horizontal, Look.Space.gutter)
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: Look.Space.snug) {
                        if let note = store.answer?.note, !note.isEmpty {
                            Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        }
                        if let failure = store.failure {
                            Text(failure).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                        }
                        content
                    }
                    .padding(.horizontal, Look.Space.gutter)
                    .padding(.top, 14)
                    .padding(.bottom, store.answer?.span == .day ? 110 : 24)
                }
            }
            // one box at the bottom, from the day view only
            if store.answer?.span == .day {
                NewBox(onAdded: { Task { await store.load() } }).padding(.horizontal, Look.Space.gutter).padding(.bottom, 8)
            }
        }
        .fingusGround()
        .toolbar(.hidden, for: .navigationBar)
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

    /// The zoom is animated with Aero's spring (the token's response and damping), so the date's element grows out of, or shrinks into, its place.
    private func zoomAnimated(_ step: Int) async {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { Task { await store.zoom(by: step) } }
    }

    // MARK: back, and tabs

    /// The way back to the home: the page has a round back key at the top; here a quiet chevron row, with room for the status bar.
    private var backRow: some View {
        HStack {
            Button(action: back) {
                HStack(spacing: Look.Space.hair) { Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold)); Text("Today").fx(Look.Size.tab, style: .subheadline) }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
            }
            .accessibilityLabel("Back to today")
            Spacer()
        }
        .padding(.horizontal, Look.Space.gutter)
    }

    /// Underline tabs: Day, Week, Month, Year (and Lists, only when a PC is set up).
    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                if store.answer?.mode == .simple {
                    tab("Today", selected: true) {}
                } else {
                    ForEach(CalendarSpan.allCases) { s in
                        tab(s.title, selected: store.span == s) { Task { await switchTo(s) } }
                    }
                }
                if store.backendKind == .pc { tab("Lists", selected: false) { openLists() } }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Look.Palette.rule).frame(height: 2)
        }
    }

    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fx(Look.Size.tab, style: .subheadline)
                .foregroundStyle(selected ? Look.Palette.fg : Look.Palette.soft)
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) { if selected { Rectangle().fill(Look.Palette.fg).frame(height: 3).offset(y: 1) } }
                .frame(minHeight: Look.Space.sizeTap)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func switchTo(_ s: CalendarSpan) async {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { Task { await store.move(span: s) } }
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

// MARK: header: arrows and the held date

struct PeriodHeader: View {
    let title: String
    var subtitle: String? = nil
    var big = false
    let isAway: Bool
    let prev: () -> Void
    let next: () -> Void
    let today: () -> Void

    var body: some View {
        VStack(spacing: Look.Space.hair / 2) {
            HStack {
                Button(action: prev) { Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.soft).frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap) }
                    .accessibilityLabel("Previous")
                Spacer()
                VStack(spacing: 0) {
                    Text(title).fx(big ? Look.Size.title : Look.Size.head, style: .title2).foregroundStyle(Look.Palette.fg)
                    if let subtitle { Text(subtitle).fx(Look.Size.subtitle, style: .subheadline).foregroundStyle(Look.Palette.soft) }
                }
                .multilineTextAlignment(.center)
                Spacer()
                Button(action: next) { Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.soft).frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap) }
                    .accessibilityLabel("Next")
            }
            if isAway {
                Button(action: today) { Text("Back to today").fx(Look.Size.question, style: .footnote).foregroundStyle(Look.Palette.now).frame(minHeight: 32) }
            }
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
        VStack(alignment: .leading, spacing: Look.Space.gap) {
            PeriodHeader(title: day.label, subtitle: day.dateText, big: true, isAway: !day.isToday,
                         prev: { Task { await store.move(date: day.prev) } }, next: { Task { await store.move(date: day.next) } },
                         today: { Task { await store.move(date: "") } })
            DayRows(day: day, metrics: .day, store: store, open: open)
        }
        .matchedGeometryEffect(id: day.date, in: zoom)
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
            Text(s.greeting).fx(TypeToken(size: 32, weight: 800), style: .largeTitle).foregroundStyle(Look.Palette.fg)
            Text(s.clock).fx(Look.Size.nextMeta, style: .title3).foregroundStyle(Look.Palette.soft)
            if let waiting = (day.rows + day.anytime).first(where: { $0.question != nil }) { PointerView(pointer: Pointer(waiting), size: .question, actions: .day(store, open: open)) }
            if let n = s.next { nextCard(n) } else { Text(s.none.isEmpty ? "Your day is clear." : s.none).fx(Look.Size.nextMeta, style: .title3) }
            if !s.behind.isEmpty { listCard("Not done yet", s.behind) }
            if !s.later.isEmpty { listCard("Later", s.later) }
            ForEach(s.did) { line in Label(line.text ?? "", systemImage: "checkmark").fx(Look.Size.nextMeta).foregroundStyle(Look.Palette.fg) }
            if !store.helpers.isEmpty { helpButton }
        }
        .matchedGeometryEffect(id: day.date, in: zoom)
    }

    private func nextCard(_ n: SimpleNext) -> some View {
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            Text("NEXT").fx(Look.Size.nextLabel, style: .caption1).tracking(1).foregroundStyle(Look.Palette.label)
            Text(n.title).fx(Look.Size.nextName, style: .title1).foregroundStyle(Look.Palette.ink)
            Text(n.line).fx(Look.Size.nextMeta, style: .subheadline).foregroundStyle(Look.Palette.label)
            Button {
                if n.source == "colony" { open(n.open); return }
                Task { if await store.setDone(n.open.id, done: !done) { done.toggle() } }
            } label: {
                // recorded where it was pressed, and taken back there
                Text(n.source == "colony" ? "Open" : done ? "Done. Tap to undo" : n.button).fx(Look.Size.nextName, style: .title2)
                    .foregroundStyle(Look.Palette.accent)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusItem, style: .continuous).fill(Look.Palette.ink))
            }
            .buttonStyle(BubblePressStyle())
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bubble(n.color, radius: Look.Bubble.radiusNext)
    }

    private func listCard(_ title: String, _ lines: [SimpleLine]) -> some View {
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            Text(title).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            ForEach(lines) { Text(($0.title ?? "") + ($0.timeText.flatMap { $0.isEmpty ? nil : " · " + $0 } ?? "")).fx(Look.Size.nextMeta, style: .title3).foregroundStyle(Look.Palette.fg) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fingusCard()
    }

    /// "Ask for help" goes to the person's helper as their Fingus, when they let one; hidden otherwise.
    private var helpButton: some View {
        Button {
            Task { if await store.askForHelp() { asked = true } }
        } label: {
            Text(asked ? "You asked for help." : "Ask for help")
                .fx(Look.Size.itemName, style: .title3).foregroundStyle(Look.Palette.fg)
                .frame(maxWidth: .infinity, minHeight: 60)
                .fingusCard(radius: Look.Bubble.radiusInput)
        }
        .buttonStyle(BubblePressStyle())
    }
}

// MARK: week, month, year

struct WeekView: View {
    let week: WeekAnswer
    let selected: String
    let store: OrganizerDayStore
    let zoom: Namespace.ID

    var body: some View {
        VStack(spacing: Look.Space.tight) {
            PeriodHeader(title: week.text, isAway: !week.days.contains { $0.today },
                         prev: { Task { await store.move(date: week.prev) } }, next: { Task { await store.move(date: week.next) } },
                         today: { Task { await store.move(date: "") } })
            VStack(spacing: Look.Space.tight) {
                ForEach(week.days) { d in
                    Button { Task { await store.move(span: .day, date: d.date) } } label: {
                        HStack(alignment: .center, spacing: Look.Space.tight) {
                            VStack(spacing: 0) {
                                Text("\(d.day)").fx(Look.Size.weekDay, style: .title3).foregroundStyle(Look.Palette.fg)
                                Text(d.weekday).fx(Look.Size.weekName, style: .caption1).foregroundStyle(Look.Palette.soft)
                            }
                            .frame(width: 44)
                            if d.free { Text("Free").fx(Look.Size.free, style: .footnote).italic().foregroundStyle(Look.Palette.soft) }
                            else { PointerFlow(pointers: d.pills.map(Pointer.init)) }
                            Spacer(minLength: 0)
                        }
                        .padding(Look.Space.inset)
                        .frame(maxWidth: .infinity, minHeight: Look.Space.sizeInput, alignment: .leading)
                        .fingusCard(radius: Look.Bubble.radiusRow)
                        .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).strokeBorder(Look.Palette.now, lineWidth: d.today ? 3 : 0))
                        .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).strokeBorder(Look.Palette.fg.opacity(0.35), lineWidth: d.date == selected && !d.today ? 2 : 0))
                    }
                    .buttonStyle(BubblePressStyle())
                    .matchedGeometryEffect(id: d.date, in: zoom)
                    .accessibilityLabel("\(d.weekday) \(d.day)\(d.today ? ", today" : ""), \(d.pills.count) things\(d.pills.contains { $0.question } ? ", a question is waiting" : "")")
                }
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
        VStack(spacing: Look.Space.tight) {
            PeriodHeader(title: month.text, isAway: !month.cells.contains { $0.today && $0.inMonth },
                         prev: { Task { await store.move(date: month.prev) } }, next: { Task { await store.move(date: month.next) } },
                         today: { Task { await store.move(date: "") } })
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.Space.tight), count: 7), spacing: Look.Space.tight) {
                ForEach(Array(month.weekdays.enumerated()), id: \.offset) { Text($0.element).fx(Look.Size.weekdayHead, style: .caption1).foregroundStyle(Look.Palette.soft) }
                ForEach(month.cells) { c in
                    Button {
                        // a first tap shows the day's things below; a second opens the day
                        if cur == c.date { Task { await store.move(span: .day, date: c.date) } } else { picked = c.date }
                    } label: {
                        ZStack(alignment: .topLeading) {
                            Text("\(c.day)").fx(Look.Size.cell, style: .footnote).padding(6)
                                .foregroundStyle(c.inMonth ? Look.Palette.fg : Look.Palette.dim)
                            HStack(spacing: Look.Space.hair) {
                                ForEach(c.pills.prefix(4)) { PointerView(pointer: Pointer($0), size: .dot) }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(.leading, 6).padding(.bottom, 7)
                            if c.question { Text("?").fx(Look.Size.cell, style: .footnote).foregroundStyle(Look.Palette.soft).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(6) }
                        }
                        .aspectRatio(1, contentMode: .fit)                  // square days
                        .background { if c.inMonth { RoundedRectangle(cornerRadius: Look.Bubble.radiusCell, style: .continuous).fill(Look.Palette.card) } }
                        .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusCell, style: .continuous).strokeBorder(Look.Palette.now, lineWidth: c.today ? 3 : 0))
                        .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusCell, style: .continuous).strokeBorder(Look.Palette.fg.opacity(0.35), lineWidth: c.date == cur && !c.today ? 2 : 0))
                    }
                    .buttonStyle(BubblePressStyle())
                    .matchedGeometryEffect(id: c.date, in: zoom)
                    .accessibilityLabel("\(c.day), \(c.count) things\(c.today ? ", today" : "")\(c.question ? ", a question is waiting" : "")")
                }
            }
            if let c = month.cells.first(where: { $0.date == cur }) {
                VStack(alignment: .leading, spacing: Look.Space.tight) {
                    Text(Self.dayName(c.date)).fx(Look.Size.subtitle, style: .footnote).foregroundStyle(Look.Palette.soft)
                    if c.pills.isEmpty { Text("Free").fx(Look.Size.free, style: .footnote).italic().foregroundStyle(Look.Palette.soft) }
                    PointerFlow(pointers: c.pills.map(Pointer.init))
                    Button { Task { await store.move(span: .day, date: c.date) } } label: {
                        Text("Open your day").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                            .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                            .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.accent))
                    }
                    .buttonStyle(BubblePressStyle())
                }
                .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fingusCard(radius: Look.Bubble.radiusRow)
                .padding(.top, 2)
            }
        }
    }

    /// "Thursday 15" from "2026-10-15".
    static func dayName(_ iso: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        f.dateFormat = "EEEE d"
        return f.string(from: d)
    }
}

struct YearView: View {
    let year: YearAnswer
    let selected: String
    let store: OrganizerDayStore
    let zoom: Namespace.ID

    var body: some View {
        VStack(spacing: Look.Space.tight) {
            PeriodHeader(title: year.text, isAway: !year.months.contains { $0.now },
                         prev: { Task { await store.move(date: year.prev) } }, next: { Task { await store.move(date: year.next) } },
                         today: { Task { await store.move(date: "") } })
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.Space.snug), count: 3), spacing: Look.Space.snug) {
                ForEach(year.months) { m in
                    Button {
                        let inside = m.days.contains { $0.date == selected }
                        Task { await store.move(span: .month, date: inside ? selected : m.month) }
                    } label: {
                        VStack(alignment: .leading, spacing: Look.Space.tight) {
                            HStack { Text(m.name).fx(Look.Size.yearMonth, style: .subheadline).foregroundStyle(Look.Palette.fg); if m.days.contains(where: { $0.question }) { Text("?").fx(Look.Size.cell, style: .footnote).foregroundStyle(Look.Palette.soft) } }
                            // shade only: a square a day, darker is fuller
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Look.Space.hair / 2), count: 7), spacing: Look.Space.hair / 2) {
                                ForEach(0..<m.offset, id: \.self) { _ in Color.clear.frame(height: Look.Space.sizeHeat) }
                                ForEach(m.days) { d in
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(d.today ? Look.Palette.now : [Look.Palette.heat1, Look.Palette.heat2, Look.Palette.heat2, Look.Palette.heat3][min(d.level, 3)])
                                        .frame(height: Look.Space.sizeHeat)
                                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Look.Palette.fg, lineWidth: d.date == selected ? 1.5 : 0))
                                        .matchedGeometryEffect(id: d.date, in: zoom)
                                }
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fingusCard(radius: Look.Bubble.radiusRow)
                        .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).strokeBorder(Look.Palette.now, lineWidth: m.now ? 3 : 0))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(m.name), \(m.days.filter { $0.count > 0 }.count) days with things\(m.days.contains { $0.question } ? ", a question is waiting" : "")")
                }
            }
        }
    }
}

// MARK: the one box

/// The box pinned at the bottom (the home mock's): a white capsule, its words in the soft colour, the mic key at the right. Organizer's quick
/// add reads the words (`quickadd`); "or ask" only when an assistant is set up. The mic key puts the cursor in the box so the keyboard's own
/// dictation key is under the thumb (the app records for this box later).
struct NewBox: View {
    var assistantSetUp = false
    var onAdded: () -> Void = {}
    @State private var text = ""
    @State private var asking: QuickAddOutcome?
    @State private var failure: String?
    @FocusState private var focused: Bool
    private let backend = OrganizerBackends.current()

    var body: some View {
        VStack(spacing: Look.Space.hair) {
            if let failure { Text(failure).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft).padding(.horizontal) }
            HStack(spacing: 0) {
                TextField("", text: $text, prompt: Text(assistantSetUp ? "Task, reminder, note, or ask…" : "Task, reminder, or note…").foregroundColor(Look.Palette.inputText))
                    .fx(Look.Size.input, style: .body)
                    .foregroundStyle(Look.Palette.fg)
                    .submitLabel(.done)
                    .focused($focused)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("quick-add-field")
                    .padding(.leading, 22)
                Button { focused = true } label: {
                    Image(systemName: "mic.fill").font(.system(size: 17, weight: .bold)).foregroundStyle(Look.Palette.ink)
                        .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap).background(Circle().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
                .padding(.trailing, 7)
                .accessibilityLabel("Dictate")
            }
            .frame(height: Look.Space.sizeInput)
            .background(Capsule().fill(Look.Palette.input)
                .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowInput.alpha), radius: Look.Bubble.shadowInput.blur / 2, x: 0, y: Look.Bubble.shadowInput.y))
        }
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
                failure = (error as? LocalizedError)?.errorDescription ?? "That didn't save. Try again."
            }
            onAdded()
        }
    }
}

struct AskItem: Identifiable {
    var outcome: QuickAddOutcome
    var id: String { outcome.question?.id ?? outcome.typed }
}

/// The question a typed line raised: the same pointer the day shows in place, drawn at sheet size (Pointer.swift). Its words are cut to the
/// item's title once, one short question, and answers that say only what differs, all one size.
struct QuickAddAsk: View {
    let outcome: QuickAddOutcome
    let backend: OrganizerBackend
    var done: () -> Void

    var body: some View {
        if let q = outcome.question {
            ScrollView {
                PointerView(pointer: Pointer(question: q), size: .sheet, actions: actions, likeliest: outcome.likeliest)
                    .padding(Look.Space.gutter)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fingusGround()
        }
    }

    private var actions: PointerActions {
        PointerActions(choose: { c in
            do { try await backend.apply(c.answer); done(); return true } catch { return false }
        }, keepPlain: { q in
            do { try await backend.keepPlain(q); done(); return true } catch { return false }
        })
    }
}
