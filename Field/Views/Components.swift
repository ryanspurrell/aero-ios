import SwiftUI
import UIKit

// Small parts every Field screen uses. They arrange Aero's tokens (Aero/Native/Tokens.swift) and its bubble look (Aero/Native/FingusUI.swift,
// `bubble`, `fingusCard`, `fingusGround`, `BubblePressStyle`), shared by path, not copied. Nothing here draws a bevel, a gloss or a segmented pill.

/// Aero's type at a token, redrawn when the person changes the text size (Dynamic Type).
struct FieldFont: ViewModifier {
    let token: TypeToken
    let style: UIFont.TextStyle
    @Environment(\.sizeCategory) private var sizeCategory

    func body(content: Content) -> some View {
        content.font(Fingus.font(token, style: style))
    }
}

extension View {
    func ft(_ token: TypeToken, style: UIFont.TextStyle = .body) -> some View { modifier(FieldFont(token: token, style: style)) }
}

/// A key: a bubble of one colour with a short plain label that says what tapping does. At least `sizeControl` tall, full width.
struct FieldButton: View {
    enum Tint { case hue(String), plain }
    let title: String
    var symbol: String? = nil
    var tint: Tint = .hue("accent")
    var enabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Look.Space.tight) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) }
                Text(title).ft(Look.Size.extra, style: .body).multilineTextAlignment(.center)
            }
            .foregroundStyle(Look.Palette.ink)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl)
            .padding(.horizontal, Look.Space.pad)
            .background { background }
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(BubblePressStyle())
        .disabled(!enabled)
    }

    @ViewBuilder private var background: some View {
        switch tint {
        case .hue(let h): Color.clear.bubble(h, radius: Look.Bubble.radiusChip)
        case .plain: RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.card.opacity(0.9))
        }
    }
}

/// A labelled box to type in. The label is shown above and is what a screen reader says; the hint is shown below when there is one.
struct FieldInput: View {
    let label: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default
    var prompt: String? = nil
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            Text(label).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft).accessibilityHidden(true)
            TextField(prompt ?? label, text: $text)
                .keyboardType(keyboard)
                .ft(Look.Size.input, style: .body)
                .foregroundStyle(Look.Palette.fg)
                .padding(.horizontal, Look.Space.pad)
                .frame(minHeight: Look.Space.sizeTap + Look.Space.hair)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.input))
                .accessibilityLabel(label)
            if let hint {
                Text(hint).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            }
        }
    }
}

/// The page title and its one quiet line, with the practice label beside it when the copy is a practice copy.
struct FieldHeader: View {
    let title: String
    var subtitle: String? = nil
    @EnvironmentObject private var store: FieldStore

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            HStack(alignment: .firstTextBaseline, spacing: Look.Space.snug) {
                Text(title).ft(Look.Size.title, style: .title1).foregroundStyle(Look.Palette.fg).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if store.practice { PracticeLabel() }
            }
            if let subtitle { Text(subtitle).ft(Look.Size.subtitle, style: .subheadline).foregroundStyle(Look.Palette.soft) }
        }
    }
}

/// "Practice copy": visible on every page while the copy is a practice copy, so nobody mistakes it for the real sheet.
struct PracticeLabel: View {
    var body: some View {
        Label("Practice copy", systemImage: "pencil.and.outline")
            .labelStyle(.titleAndIcon)
            .ft(Look.Size.pill, style: .caption1)
            .foregroundStyle(Look.Palette.ink)
            .padding(.horizontal, Look.Space.snug).padding(.vertical, Look.Space.hair)
            .background(Capsule().fill(Fingus.hue("orange").base))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Practice copy")
    }
}

/// A state or answer as a symbol and words (never colour alone).
struct StatePill: View {
    let symbol: String
    let text: String
    var body: some View {
        Label(text, systemImage: symbol)
            .ft(Look.Size.pill, style: .footnote)
            .foregroundStyle(Look.Palette.ink)
            .padding(.horizontal, Look.Space.snug).padding(.vertical, Look.Space.chip)
            .background(Capsule().fill(Look.Palette.card.opacity(0.85)))
    }
}

/// Buttons side by side, or one under another when the text is large.
struct FieldButtonRow<Content: View>: View {
    @Environment(\.dynamicTypeSize) private var size
    @ViewBuilder var content: Content
    var body: some View {
        if size.isAccessibilitySize {
            VStack(spacing: Look.Space.tight) { content }
        } else {
            HStack(spacing: Look.Space.tight) { content }
        }
    }
}

/// A plain card with a title line and its content.
struct FieldCard<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            if let title { Text(title).ft(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).accessibilityAddTraits(.isHeader) }
            content
        }
        .padding(Look.Space.pad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fingusCard()
    }
}

/// The page body: scrolls, gutters from the tokens, the ground behind.
struct FieldPage<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.gap) { content }
                .padding(.horizontal, Look.Space.gutter)
                .padding(.top, Look.Space.pad).padding(.bottom, Look.Space.clearance)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .fingusGround()
    }
}

/// Plain body text.
struct FieldNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.soft).fixedSize(horizontal: false, vertical: true)
    }
}

/// The system share sheet, shown only when the person taps share. Items are a file or text; the file is removed when the sheet closes.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var cleanup: URL? = nil
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let c = UIActivityViewController(activityItems: items, applicationActivities: nil)
        let url = cleanup
        c.completionWithItemsHandler = { _, _, _, _ in if let url { try? FileManager.default.removeItem(at: url) } }
        return c
    }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}
