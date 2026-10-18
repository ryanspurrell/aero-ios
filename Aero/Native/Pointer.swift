import SwiftUI

// Everything the app shows of a thing is a pointer, drawn here and nowhere else (the owner, 2026-10-15: "everything in app needs to be pointers";
// projects/fingusfacts/design__boards_as_pages_2026-10-06.md, "How boards work now"). A pointer names its owner and the owner's id; the part
// says what (its parts, ranked: the title first, then the time, then the second line); the place says how big (PointerSize); the look tokens
// say how (Tokens.swift). A screen builds pointers from the answer it was given and puts each in a place; it has no view of its own for an
// item. The web page draws the same pointers from the same answer.

/// One thing to show: a pointer to its owner's thing, with the parts the owner gave, ranked.
struct Pointer: Identifiable {
    /// Whose thing it is: "organizer", "colony", "chats"...
    var owner: String
    var id: String
    // the parts, in rank order (a smaller size shows fewer of them: the title always, the rest as room allows)
    var title: String
    var time: String? = nil
    var meta: String? = nil
    var done = false
    /// A word of the owner's colour (Organizer's name, or Colony's hex) and symbol; the colour is never the only signal (the words go with it).
    var colorValue: String? = nil
    var icon: String? = nil
    /// A question that is waiting on this thing, kept in place and changeable.
    var question: Question? = nil
    var open: OpenRef? = nil
    // for the home's small pointers (Carry on, the keys)
    var label: String? = nil
    var badge: String? = nil
    var dot = false
    /// How long until it, as the day says it (the big Next block).
    var until: String? = nil
    /// "Moved from Thursday" and the like, for a pill's spoken label (a pill has no second line).
    var markText: String? = nil
    /// A quiet row: it only says where a thing went or was due (state "moved" or "was_due"), so it is drawn lighter and never as next.
    var quiet = false

    var uid: String { owner + ":" + id }
}

/// How big the place makes it. The same pointer is drawn at any of these.
enum PointerSize {
    case next        // the home's big block
    case block       // a thing on the spine, or set apart (B1)
    case pill        // a week's or a month's coloured pill
    case dot         // a month day's coloured dot
    case card        // the home's Carry on card
    case key         // the home's small Chats / Recordings key
    case question    // a waiting question, in place under its day
    case sheet       // the same question, filling a sheet
}

/// What a tap on a pointer does; the place gives it.
struct PointerActions {
    var open: (OpenRef) -> Void = { _ in }
    /// An answer to a question was chosen; true when it was kept.
    var choose: (QuestionChoice) async -> Bool = { _ in false }
    /// "Something else": none of the answers fits.
    var keepPlain: (Question) async -> Bool = { _ in false }
}

// MARK: pointers made from the answers owners give

extension Pointer {
    /// A thing of the day (Organizer's, or Colony's event).
    init(_ item: DayItem) {
        self.init(owner: item.source ?? "organizer", id: item.id, title: item.title ?? "", time: item.timeText,
                  meta: Pointer.meta(of: item), done: item.state == "done", colorValue: item.color, icon: item.icon,
                  question: item.question, open: item.open, until: item.until)
        quiet = Pointer.isQuiet(item.state)
        // the old day's row opens the new place: the day it was moved to
        if item.state == "moved", let to = item.movedTo { open = OpenRef(app: Pointer.dayApp, id: to.date, occurrence: nil) }
    }

    /// The owner name of a pointer that opens a day of the calendar rather than a thing.
    static let dayApp = "organizer-day"

    static func isQuiet(_ state: String?) -> Bool { state == "moved" || state == "was_due" }

    /// A week's or a month's pill.
    init(_ pill: Pill) {
        self.init(owner: pill.source, id: pill.id, title: pill.title, time: pill.timeText.isEmpty ? nil : pill.timeText, done: pill.state == "done",
                  colorValue: pill.color, icon: pill.icon, question: nil)
        quiet = Pointer.isQuiet(pill.state)
        if pill.question { meta = "?" }
        markText = pill.markText
    }

    /// The home's Carry on card and small keys.
    init(_ key: HomeExtras.Key) {
        self.init(owner: key.id, id: key.id, title: key.name, colorValue: key.hue, badge: key.letter, dot: key.dot)
    }

    /// A question as a pointer of its own (the quick-add sheet).
    init(question q: Question) {
        self.init(owner: "organizer", id: q.id, title: QuestionWords.make(question: q).title, question: q)
    }

    static func meta(of item: DayItem) -> String? {
        // a quiet row says only where the thing went or was due
        if Pointer.isQuiet(item.state) { return item.markText }
        var base: String?
        if item.state == "done" { base = "Done" + (item.doneAtText.map { " at " + $0 } ?? "") }
        // no record of completion is none, not late (Aryn, 2026-10-17); the words are picked, not grounded
        else if item.state == "unmarked" { base = "From before, not marked done" }
        else if let until = item.until { base = until }
        else if let end = item.endText, !end.isEmpty { base = "Until " + end }
        else if item.unmarked == true { base = "Not marked done" }
        else if item.isRepeat == true { base = "Repeats" }
        // "Moved from Thursday", or "Was due Thursday" on the day it was done, beside the rest
        let said = [base, item.markText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        return said.isEmpty ? nil : said
    }
}

// MARK: the one drawer

struct PointerView: View {
    let pointer: Pointer
    let size: PointerSize
    var actions = PointerActions()
    var likeliest: Int? = nil
    @State private var chosen: Int?
    @State private var failure: String?

    var body: some View {
        switch size {
        case .next: next
        case .block: block
        case .pill: pill
        case .dot: Circle().fill(Fingus.hue(pointer.colorValue).base).frame(width: Look.Space.sizeDot, height: Look.Space.sizeDot)
                .accessibilityLabel(pointer.title)
        case .card: card
        case .key: key
        case .question: question
        case .sheet: sheet
        }
    }

    private func tap(_ body: @escaping () -> Void) -> () -> Void { body }
    private func open() { if let o = pointer.open { actions.open(o) } }

    // MARK: next (the home's big block)

    private var next: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NEXT").fx(Look.Size.nextLabel, style: .caption1).tracking(1).foregroundStyle(Look.Palette.label)
                Text(pointer.title).fx(Look.Size.nextName, style: .title1).foregroundStyle(Look.Palette.ink).padding(.top, Look.Space.hair)
                if let line = pointer.until ?? pointer.meta {
                    Text(line).fx(Look.Size.nextMeta, style: .subheadline).foregroundStyle(Look.Palette.label)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Look.Space.gutter).padding(.vertical, Look.Space.pad)
            .background {
                let c = Fingus.hue(pointer.colorValue)
                RoundedRectangle(cornerRadius: Look.Bubble.radiusNext, style: .continuous)
                    .fill(LinearGradient(colors: [c.light, c.base], startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)))
                    .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowNext.alpha), radius: Look.Bubble.shadowNext.blur / 2, x: 0, y: Look.Bubble.shadowNext.y)
            }
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel("Next: \(pointer.title), \(pointer.until ?? ""). Opens your day.")
    }

    // MARK: block (B1)

    private var block: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 1) {
                Text(pointer.title).fx(Look.Size.itemName)
                    .strikethrough(pointer.done)
                    .foregroundStyle(pointer.done ? Look.Palette.doneText : Look.Palette.ink)
                if let meta = pointer.meta { Text(meta).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(pointer.done ? Look.Palette.doneMeta : Look.Palette.soft) }
            }
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl - 2 * Look.Space.padY, alignment: .leading)
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .bubble(pointer.colorValue, done: pointer.done || pointer.quiet)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel([pointer.title, pointer.time, pointer.meta, pointer.owner == "colony" ? "from the calendar" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    // MARK: pill

    private var pill: some View {
        HStack(spacing: Look.Space.hair) {
            Text((pointer.time.map { Self.shortTime($0) + " " } ?? "") + pointer.title).lineLimit(1).fx(Look.Size.pill, style: .footnote)
            if pointer.meta == "?" { Text("?").fx(Look.Size.pill, style: .footnote) }
        }
        .foregroundStyle(pointer.done || pointer.quiet ? Look.Palette.doneText : Look.Palette.ink)
        .padding(.horizontal, Look.Space.tight).padding(.vertical, Look.Space.hair)
        .bubble(pointer.colorValue, done: pointer.done || pointer.quiet, radius: Look.Bubble.radiusPill, soft: true)
        .accessibilityLabel([pointer.title, pointer.time, pointer.markText].compactMap { $0 }.joined(separator: ", "))
    }

    static func shortTime(_ t: String) -> String {
        t.replacingOccurrences(of: ":00", with: "").replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "")
    }

    // MARK: card and key (the home's small pointers)

    private var card: some View {
        HStack(spacing: Look.Space.snug) {
            VStack(alignment: .leading, spacing: 0) {
                Text((pointer.label ?? "").uppercased()).fx(Look.Size.carryLabel, style: .caption1).foregroundStyle(Look.Palette.label)
                Text(pointer.title).fx(Look.Size.carryTitle, style: .body).foregroundStyle(Look.Palette.ink)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.label)
        }
        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.inset)
        .background {
            let c = Fingus.hue(pointer.colorValue)
            RoundedRectangle(cornerRadius: Look.Bubble.radiusCard, style: .continuous)
                .fill(LinearGradient(colors: [c.light, c.base], startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)))
                .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowCard.alpha), radius: Look.Bubble.shadowCard.blur / 2, x: 0, y: Look.Bubble.shadowCard.y)
        }
    }

    private var key: some View {
        HStack(spacing: Look.Space.tight) {
            Text(pointer.badge ?? "").fx(Look.Size.pill, style: .caption1).foregroundStyle(Look.Palette.ink)
                .frame(width: Look.Space.sizeTap - 18, height: Look.Space.sizeTap - 18)
                .background(RoundedRectangle(cornerRadius: Look.Space.tight + 1, style: .continuous)
                    .fill(LinearGradient(colors: [Fingus.hue(pointer.colorValue).light, Fingus.hue(pointer.colorValue).base], startPoint: .topLeading, endPoint: .bottomTrailing)))
            Text(pointer.title).fx(Look.Size.extra, style: .subheadline).foregroundStyle(Look.Palette.fg).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: Look.Space.sizeInput + Look.Space.hair)
        .fingusCard(radius: Look.Bubble.radiusExtra)
        .overlay(alignment: .topTrailing) {
            if pointer.dot { Circle().fill(Look.Palette.now).frame(width: Look.Space.snug, height: Look.Space.snug).padding(.top, Look.Space.tight).padding(.trailing, Look.Space.tight + 2) }
        }
    }

    // MARK: a question kept in place

    private var words: QuestionWords? { pointer.question.map { QuestionWords.make(question: $0) } }

    private var question: some View {
        Group {
            if let q = pointer.question, let words {
                VStack(alignment: .leading, spacing: Look.Space.tight) {
                    Text("\(words.title) \u{2014} \(words.ask)").fx(Look.Size.question, style: .subheadline).foregroundStyle(Look.Palette.fg)
                    ViewThatFits {
                        HStack(spacing: Look.Space.tight) { chips(q, words) }
                        VStack(spacing: Look.Space.tight) { chips(q, words) }
                    }
                    if chosen != nil {
                        Text("Saved. Tap another to change it.").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }
                .padding(.horizontal, Look.Space.inset).padding(.vertical, Look.Space.tight + 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusQuestion, style: .continuous).fill(Look.Palette.questionFill))
                .overlay(RoundedRectangle(cornerRadius: Look.Bubble.radiusQuestion, style: .continuous)
                    .strokeBorder(Look.Palette.questionLine, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Question: \(words.title), \(words.ask)")
            }
        }
    }

    /// Every answer is one size: the same width and the same height.
    @ViewBuilder private func chips(_ q: Question, _ words: QuestionWords) -> some View {
        ForEach(Array(zip(q.choices, words.chips)), id: \.0.index) { c, chip in
            Button {
                Task { if await actions.choose(c) { chosen = c.index } }
            } label: {
                HStack(spacing: Look.Space.hair) {
                    if chosen == c.index { Image(systemName: "checkmark") }
                    Text(chip.text).multilineTextAlignment(.center)
                }
                .fx(Look.Size.question, style: .subheadline)
                .foregroundStyle(chosen == c.index ? Look.Palette.accent : Look.Palette.ink)
                .frame(maxWidth: .infinity, minHeight: Look.Space.sizeTap)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(chosen == c.index ? Look.Palette.ink : Look.Palette.accent))
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityAddTraits(chosen == c.index ? .isSelected : [])
        }
    }

    // MARK: the same question filling a sheet

    private var sheet: some View {
        Group {
            if let q = pointer.question, let words {
                VStack(alignment: .leading, spacing: Look.Space.tight) {
                    Text(words.title).fx(Look.Size.title, style: .title1).foregroundStyle(Look.Palette.fg)
                    if let typed = words.typed { Text(typed).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                    Text(words.ask).fx(Look.Size.itemName, style: .body).foregroundStyle(Look.Palette.fg)
                        .padding(.top, Look.Space.tight).padding(.bottom, Look.Space.hair)
                    ForEach(Array(zip(q.choices, words.chips)), id: \.0.index) { c, chip in
                        answer(chip.text, hue: "accent", note: likeliest == c.index ? "Likeliest" : nil) {
                            Task { if await actions.choose(c) == false { failure = "That didn't save. Try again." } }
                        }
                    }
                    answer("Something else", hue: nil, note: nil) {
                        Task { if await actions.keepPlain(q) == false { failure = "That didn't save. Try again." } }
                    }
                    if let failure { Text(failure).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.now) }
                }
            }
        }
    }

    /// One answer: the same width and height as every other, its words at the left. `hue` nil is the plain card.
    private func answer(_ text: String, hue: String?, note: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(text).fx(Look.Size.itemName).foregroundStyle(hue == nil ? Look.Palette.fg : Look.Palette.ink).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let note { Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.label) }
            }
            .padding(.horizontal, Look.Space.pad)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
            .background {
                if let hue { Color.clear.bubble(hue) } else { Color.clear.fingusCard(radius: Look.Bubble.radiusItem) }
            }
        }
        .buttonStyle(BubblePressStyle())
    }
}

extension PointerActions {
    /// The day's own: opening goes to the owner's screen; an answer is the same `update` and is kept by the store.
    static func day(_ store: OrganizerDayStore, open: @escaping (OpenRef) -> Void) -> PointerActions {
        // a quiet "moved to" row names a day, not a thing: tapping it goes to that day
        PointerActions(open: { o in
            if o.app == Pointer.dayApp { Task { await store.move(date: o.id) } } else { open(o) }
        }, choose: { await store.choose($0) }, keepPlain: { _ in false })
    }
}

/// A plain wrapping layout (iOS 16's Layout protocol): items flow left to right and onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = Look.Space.tight

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing; rowHeight = max(rowHeight, size.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: min(maxX, width), height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Pointers in a wrapping row, all at one size (a week's row, a month's day).
struct PointerFlow: View {
    let pointers: [Pointer]
    var size: PointerSize = .pill
    var body: some View {
        FlowLayout(spacing: Look.Space.tight) {
            ForEach(pointers) { PointerView(pointer: $0, size: size) }
        }
    }
}
