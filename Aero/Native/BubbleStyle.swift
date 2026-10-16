import SwiftUI

/// B1, the style the owner chose for the day's things (projects/aero/mockups/organizer_item_bubbly_2026-10-15.html; "bubbly and light,
/// bouncy", "we've moved off the physical button design"): a rounded block, a gentle gradient of the thing's own colour from its light tone
/// to its colour, a soft shadow in that same colour, no bevel, no raised card, no tile for the symbol. Done is a pale plain block with no
/// shadow. The colour is the owner's (Organizer's or Colony's, see organizerColor); the symbol and the words stay inside the block, so
/// colour is never the only signal.
struct Bubble: ViewModifier {
    let colorValue: String?
    var done = false
    var radius: CGFloat = 22
    var lift: CGFloat = 5

    func body(content: Content) -> some View {
        let c = organizerColor(colorValue)
        content
            .foregroundStyle(done ? Color.secondary : Color.black.opacity(0.85))
            .background {
                if done {
                    RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.06))
                } else {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(LinearGradient(colors: [c.opacity(0.38), c.opacity(0.9)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .shadow(color: c.opacity(0.5), radius: lift * 1.4, x: 0, y: lift)
                }
            }
    }
}

/// The pale plain block for what is not a thing of the day itself (a week's row, a month's day, a list): no bevel, no shadow.
struct PaleBlock: ViewModifier {
    var radius: CGFloat = 18
    func body(content: Content) -> some View {
        content.background(RoundedRectangle(cornerRadius: radius).fill(Color.primary.opacity(0.06)))
    }
}

extension View {
    func bubble(_ colorValue: String?, done: Bool = false, radius: CGFloat = 22, lift: CGFloat = 5) -> some View {
        modifier(Bubble(colorValue: colorValue, done: done, radius: radius, lift: lift))
    }

    func paleBlock(radius: CGFloat = 18) -> some View {
        modifier(PaleBlock(radius: radius))
    }
}

/// Pressed: a slight squash, then it springs back. The spring is the system one that matches Aero's `--ease-spring` (response 0.55,
/// damping fraction 0.825), the squash 0.96 as the mock shows; with Reduce Motion on, nothing moves.
struct BubblePressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.825), value: configuration.isPressed)
    }
}
