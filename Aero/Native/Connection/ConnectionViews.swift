import SwiftUI

// The island's connection mark, the Find out why sheet, and the keys of a failure line. Look is Aero's (Tokens.swift); every key is a visible
// tap, and a reading is told by its words and a symbol, never by colour alone.

/// A key of the mock: a pill that says what tapping it does.
struct FingusKey: View {
    let title: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).fx(Look.Size.pill, style: .footnote).foregroundStyle(prominent ? Look.Palette.ink : Look.Palette.fg)
                .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(prominent ? Look.Palette.accent : Look.Palette.card))
        }
        .buttonStyle(BubblePressStyle())
    }
}

/// The Find out why key alone, for a failure line that has no Try again of its own. Shown only with a PC to ask.
struct FindOutWhyKey: View {
    let diagnosis: String
    @State private var asking = false

    var body: some View {
        if ConnectionStatus.whyOffered(hasAddress: AppInfo.address != nil) {
            FingusKey(title: "Find out why", prominent: false) { asking = true }
                .sheet(isPresented: $asking) { FindOutWhySheet(failure: diagnosis) { asking = false } }
        }
    }
}

/// The two keys of a failure line: the one that does what can be done now, and, with a PC to ask, Find out why (Doctor's diagnosis of this
/// failure). Nothing changes by opening it; it only looks.
struct FailureKeys: View {
    let tryAgain: String
    let diagnosis: String
    var retry: () -> Void
    @State private var asking = false

    var body: some View {
        HStack(spacing: Look.Space.tight) {
            FingusKey(title: tryAgain, action: retry)
            if ConnectionStatus.whyOffered(hasAddress: AppInfo.address != nil) {
                FingusKey(title: "Find out why", prominent: false) { asking = true }
            }
        }
        .sheet(isPresented: $asking) {
            FindOutWhySheet(failure: diagnosis) { asking = false }
        }
    }
}

/// Doctor's diagnosis of one failure: the checks it can run, then at most one question (Yes, No, Not sure), then the step that fits.
struct FindOutWhySheet: View {
    let failure: String
    var close: () -> Void
    @StateObject private var runner = DiagnosisRunner()

    private func name(_ a: DiagAns) -> String {
        switch a {
        case .yes: return "Yes"
        case .no: return "No"
        case .notSure: return "Not sure"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.gap) {
            Text("Find out why").fx(Look.Size.head, style: .title2).foregroundStyle(Look.Palette.fg)
            if let shown = runner.shown {
                if let q = shown.question {
                    Text(q.text).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.fg)
                }
                if !shown.text.isEmpty, shown.question == nil || shown.isStillOpen {
                    Text(shown.text).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                }
                if shown.question != nil {
                    HStack(spacing: Look.Space.tight) {
                        ForEach(DiagAns.allCases, id: \.self) { a in
                            FingusKey(title: name(a), prominent: a != .notSure) { Task { await runner.run(failure: failure, answer: a) } }
                        }
                    }
                }
            } else {
                Text("Checking").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            }
            HStack(spacing: Look.Space.tight) {
                FingusKey(title: "Check again", prominent: false) { Task { await runner.run(failure: failure) } }
                FingusKey(title: "Close", prominent: false, action: close)
            }
            Spacer(minLength: 0)
        }
        .padding(Look.Space.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fingusGround()
        .presentationDetents([.medium])
        .task { await runner.run(failure: failure) }
        .accessibilityElement(children: .contain)
    }
}

/// The island's connection mark: which place the app uses and whether it reached it, since when. Four readings (yes, no, none, all). With a PC
/// it is a key: tapping it opens Find out why. With none it is only the mark, because Doctor is a part of the PC.
struct ConnectionIsland: View {
    @ObservedObject private var monitor = ConnectionMonitor.shared
    @State private var asking = false

    private var mark: some View {
        HStack(spacing: Look.Space.hair) {
            Image(systemName: ConnectionStatus.symbol(monitor.shown.reading)).font(.system(size: 13, weight: .bold)).accessibilityHidden(true)
            Text(monitor.words).fx(Look.Size.itemMeta, style: .caption1).lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(Look.Palette.soft)
        .padding(.horizontal, Look.Space.tight)
        .frame(minHeight: Look.Space.sizeTap)
    }

    var body: some View {
        if ConnectionStatus.whyOffered(hasAddress: monitor.backend == .pc) {
            Button { asking = true } label: { mark }
                .buttonStyle(BubblePressStyle())
                .accessibilityLabel(monitor.words)
                .accessibilityHint("Opens Find out why")
                .accessibilityIdentifier("connection-island")
                .sheet(isPresented: $asking) {
                    FindOutWhySheet(failure: "pc_unreachable") { asking = false }
                }
        } else {
            mark.accessibilityElement(children: .ignore).accessibilityLabel(monitor.words).accessibilityIdentifier("connection-island")
        }
    }
}
