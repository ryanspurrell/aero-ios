import SwiftUI
import UIKit

// Aero's look in SwiftUI, from the approved mocks (projects/aero/mockups: ios_home_organizer_first, organizer_item_bubbly column B1,
// organizer_timeline, organizer_calendar_views). Every number here is a token (Tokens.swift, generated from aero_tokens.py); this file
// only arranges them. Nothing uses the system's navigation bar, list or button styles where the mock draws something else.

// MARK: type: Exo 2

enum Fingus {
    /// Exo 2 at a size and weight (the font is a variable font; the weight is its `wght` axis), scaled with Dynamic Type. Falls back to the
    /// system face if the file did not load.
    static func uiFont(_ t: TypeToken) -> UIFont {
        let axis = 2003265652          // 'wght'
        guard let base = UIFont(name: "Exo2-Regular", size: t.size) else {
            return UIFont.systemFont(ofSize: t.size, weight: t.weight >= 700 ? .bold : t.weight >= 600 ? .semibold : .regular)
        }
        let descriptor = base.fontDescriptor.addingAttributes([UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [axis: t.weight]])
        return UIFont(descriptor: descriptor, size: t.size)
    }

    static func font(_ t: TypeToken, style: UIFont.TextStyle = .body) -> Font {
        Font(UIFontMetrics(forTextStyle: style).scaledFont(for: uiFont(t)))
    }

    /// A colour Organizer named (or Colony's hex), as the mock draws a block: its light end and its base.
    static func hue(_ value: String?) -> (light: Color, base: Color) {
        guard let value, !value.isEmpty else { return Look.Hue.accent }
        if let known = Look.Hue.byName[value] { return known }
        if value.hasPrefix("#"), let rgb = UInt32(value.dropFirst(), radix: 16) {
            let r = Double((rgb >> 16) & 0xff) / 255, g = Double((rgb >> 8) & 0xff) / 255, b = Double(rgb & 0xff) / 255
            // a hex colour (a calendar's) is the base; its light end is halfway to white, as the mock's pairs are
            return (Color(red: r + (1 - r) * 0.5, green: g + (1 - g) * 0.5, blue: b + (1 - b) * 0.5), Color(red: r, green: g, blue: b))
        }
        return Look.Hue.accent
    }
}

extension View {
    /// The mock's type at this token.
    func fx(_ t: TypeToken, style: UIFont.TextStyle = .body) -> some View { font(Fingus.font(t, style: style)) }

    /// The page ground: the mock's soft gradient, under everything, to the screen's edges.
    func fingusGround() -> some View {
        background(LinearGradient(colors: [Look.Palette.groundTop, Look.Palette.groundBottom], startPoint: .top, endPoint: .bottom).ignoresSafeArea())
    }

    /// A plain card of the mock: its colour, its radius, its soft shadow.
    func fingusCard(radius: CGFloat = Look.Bubble.radiusCard) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Look.Palette.card)
            .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowCard.alpha), radius: Look.Bubble.shadowCard.blur / 2, x: 0, y: Look.Bubble.shadowCard.y))
    }

    /// B1: a gradient of the thing's own colour, a soft shadow in that colour, no bevel. Done: pale and plain, no shadow.
    func bubble(_ colorValue: String?, done: Bool = false, radius: CGFloat = Look.Bubble.radiusItem, soft: Bool = false) -> some View {
        modifier(Bubble(colorValue: colorValue, done: done, radius: radius, soft: soft))
    }
}

struct Bubble: ViewModifier {
    let colorValue: String?
    var done = false
    var radius: CGFloat = Look.Bubble.radiusItem
    /// A pill: the gradient only, no shadow (the calendar mock's pills)
    var soft = false

    func body(content: Content) -> some View {
        let c = Fingus.hue(colorValue)
        // the CSS gradient angle (160deg) as two points on the unit square
        let a = Look.Bubble.fillAngleDegrees * .pi / 180
        let dx = sin(a) / 2, dy = -cos(a) / 2
        content.background {
            if done {
                RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Look.Palette.doneFill)
            } else {
                ZStack {
                    if !soft {
                        // the shadow's source is the block shrunk by the spread, so only its soft edge shows (CSS: 0 6px 14px -4px)
                        RoundedRectangle(cornerRadius: max(0, radius + Look.Bubble.shadowSpread), style: .continuous)
                            .fill(c.base)
                            .padding(-Look.Bubble.shadowSpread)
                            .shadow(color: c.base.opacity(Look.Bubble.shadowMix), radius: Look.Bubble.shadowBlur / 2, x: 0, y: Look.Bubble.shadowY)
                    }
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [c.light, c.base], startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy), endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
                    if !soft {
                        // the inset 1px highlight along the top
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .strokeBorder(LinearGradient(colors: [Color.white.opacity(Look.Bubble.highlight), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.3)), lineWidth: 1)
                    }
                }
            }
        }
    }
}

/// Pressed: a slight squash, then it springs back (Aero's spring; nothing moves when Reduce Motion is on).
struct BubblePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? Look.pressKey : 1)
            .animation(reduceMotion ? nil : .spring(response: Look.springResponse, dampingFraction: Look.springDamping), value: configuration.isPressed)
    }
}

// MARK: symbols

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

// MARK: the time spine

/// Where the spine sits: the home's mock and the day's mock differ a little (the home hangs Next and the rest on a narrower line).
struct SpineMetrics {
    var timeWidth: CGFloat
    var lineX: CGFloat
    var blockX: CGFloat
    static let home = SpineMetrics(timeWidth: 40, lineX: 53, blockX: 70)
    static let day = SpineMetrics(timeWidth: 46, lineX: 80, blockX: 96)
}

/// One time on the spine: its own time at the left, its own knot on the line, then what is at that time. The knot and the time sit level with
/// the middle of the block (the day's mock), or near the top of a tall one (the home's Next).
struct SpineRow<Content: View>: View {
    let metrics: SpineMetrics
    let timeText: String
    let knot: Color
    var centered = true
    @ViewBuilder var content: Content

    private var knotView: some View {
        Circle().fill(knot)
            .overlay(Circle().strokeBorder(Look.Palette.groundTop, lineWidth: 3))
            .frame(width: Look.Space.sizeKnot, height: Look.Space.sizeKnot)
            .accessibilityHidden(true)
    }

    var body: some View {
        HStack(alignment: centered ? .center : .top, spacing: 0) {
            ClockText(text: timeText).frame(width: metrics.timeWidth, alignment: .trailing).padding(.top, centered ? 0 : 14)
            Color.clear.frame(width: metrics.blockX - metrics.timeWidth, height: 1)
            content
        }
        .overlay(alignment: centered ? .leading : .topLeading) {
            knotView.offset(x: metrics.lineX - 6.5, y: centered ? 0 : 24)
        }
    }
}

/// "10:30 AM" as 10:30 over a small AM, so two times are told apart at a glance and the line stays narrow.
struct ClockText: View {
    let text: String
    var body: some View {
        let parts = text.split(separator: " ").map(String.init)
        VStack(alignment: .trailing, spacing: -1) {
            Text(parts.first ?? text).fx(Look.Size.spineTime, style: .footnote).foregroundStyle(Look.Palette.soft)
            if parts.count > 1 { Text(parts[1]).font(Fingus.font(TypeToken(size: 10, weight: 700), style: .caption2)).foregroundStyle(Look.Palette.soft.opacity(0.8)) }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

/// The spine itself: the vertical line behind the rows.
struct SpineColumn<Content: View>: View {
    let metrics: SpineMetrics
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .background(alignment: .topLeading) {
                Capsule().fill(Look.Palette.line).frame(width: 3).padding(.vertical, 10).offset(x: metrics.lineX - 1.5)
            }
    }
}

/// The red Now line and its pill, where now falls.
struct NowRow: View {
    let metrics: SpineMetrics
    let timeText: String
    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Look.Palette.now).frame(height: 2).padding(.leading, metrics.blockX - 34)
            Text("Now").fx(Look.Size.now, style: .caption1)
                .padding(.horizontal, Look.Space.tight).padding(.vertical, Look.Space.hair / 2)
                .background(Capsule().fill(Look.Palette.now))
                .foregroundStyle(.white)
        }
        .frame(minHeight: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now, \(timeText)")
    }
}

/// "Free until 4:00 PM", as the web says it (the rows come from the same Python, organizer_timeline.py).
struct FreeRow: View {
    let metrics: SpineMetrics
    let text: String
    var body: some View {
        Text(text).fx(Look.Size.free, style: .footnote).italic().foregroundStyle(Look.Palette.soft)
            .padding(.leading, metrics.blockX - 16)
    }
}

// MARK: a thing of the day, B1

struct ItemBlock: View {
    let item: DayItem
    var onTap: () -> Void = {}

    private var done: Bool { item.state == "done" }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title ?? "").fx(Look.Size.itemName)
                    .strikethrough(done)
                    .foregroundStyle(done ? Look.Palette.doneText : Look.Palette.fgOnBlock)
                if let meta { Text(meta).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(done ? Look.Palette.doneMeta : Look.Palette.soft) }
            }
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl - 2 * Look.Space.padY, alignment: .leading)
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .bubble(item.color, done: done)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel([item.title, item.timeText, meta, item.source == "colony" ? "from the calendar" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var meta: String? {
        if done { return "Done" + (item.doneAtText.map { " at " + $0 } ?? "") }
        if item.state == "overdue" { return "From before" }
        if let until = item.until { return until }
        if let end = item.endText, !end.isEmpty { return "Until " + end }
        if item.late == true { return "Not done" }
        return item.isRepeat == true ? "Repeats" : nil
    }
}

extension Look.Palette {
    /// Text on a coloured block: the mock's own ink, in both modes (a block's colours are the same pastel by day and night).
    static let fgOnBlock = Look.Palette.ink
}

// MARK: a question, in place

/// A question that is still open, in place: a dashed card, the thing and what is asked, the answers as accent chips. The answer is
/// recorded where it was given; the chosen chip is marked and the others stay tappable to change it.
struct QuestionInPlace: View {
    let question: Question
    let store: OrganizerDayStore
    @State private var chosen: Int?

    private var words: QuestionWords { QuestionWords.make(question: question) }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            Text("\(words.title) \u{2014} \(words.ask)").fx(Look.Size.question, style: .subheadline).foregroundStyle(Look.Palette.fg)
            ViewThatFits {
                HStack(spacing: Look.Space.tight) { chips }
                VStack(spacing: Look.Space.tight) { chips }
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

    /// Every answer is one size: the same width and the same height.
    @ViewBuilder private var chips: some View {
        ForEach(Array(zip(question.choices, words.chips)), id: \.0.index) { c, chip in
            Button {
                Task { if await store.choose(c) { chosen = c.index } }
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
}

// MARK: pills (week, month)

/// Coloured pills in time order, wrapping; each with its words (colour is never the only signal).
struct FlowPills: View {
    let pills: [Pill]
    var body: some View {
        FlowLayout(spacing: Look.Space.tight) {
            ForEach(pills) { p in
                HStack(spacing: Look.Space.hair) {
                    Text((p.timeText.isEmpty ? "" : p.timeText.replacingOccurrences(of: ":00", with: "").replacingOccurrences(of: " AM", with: "").replacingOccurrences(of: " PM", with: "") + " ") + p.title)
                        .lineLimit(1).fx(Look.Size.pill, style: .footnote)
                    if p.question { Text("?").fx(Look.Size.pill, style: .footnote) }
                }
                .foregroundStyle(Look.Palette.ink)
                .padding(.horizontal, Look.Space.tight).padding(.vertical, Look.Space.hair)
                .bubble(p.color, done: p.state == "done", radius: Look.Bubble.radiusPill, soft: true)
            }
        }
    }
}

/// A plain wrapping layout (iOS 16's Layout protocol): items flow left to right and onto the next line.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

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
