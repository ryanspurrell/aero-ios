import SwiftUI

/// The app's first screen, organizer first (the approved mock projects/aero/mockups/ios_home_organizer_first_2026-10-15.html): the day is
/// most of the screen. Next is big and the rest of today hangs on one time line with its times at the left, so they read as one day; a
/// waiting question sits in place with one-tap choices (recorded where tapped; the others stay tappable to change it); a calm line when
/// nothing else is left; "Task, reminder, note, or ask…" is always at the bottom. Any of it opens the day timeline, which zooms out to
/// week, month and year.
///
/// The data is the day's (`calendar`, span day): Organizer's tasks and Colony's events, each its owner's. The board's other pointers
/// (one Carry on card with its three kinds kept apart, and small Chats / Recordings / Assistant keys shown only when they have something
/// or are set up) belong to other apps and are not drawn here yet: they wait for the shared pieces (branch one-look), and the home stays
/// complete without them, as the mock's quiet version is. No Assistant key at all while none is set up.
///
/// What each pointer sends is kind, ranked data, actions, answer state, colour and icon, never size or style; this view fits it to the
/// slot and to Dynamic Type (ViewThatFits), falling back from the time line to a plain stack when the text is large.
struct OrganizerHomeScreen: View {
    @StateObject private var store = OrganizerDayStore()
    var openDay: () -> Void = {}
    var open: (OpenRef) -> Void = { _ in }
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let day = store.answer?.day {
                        Text(day.dateText).font(.subheadline).bold().foregroundStyle(.secondary)
                        // Next and the rest hang on one time line; at accessibility sizes the times would not fit at the left, so the
                        // same things are stacked with their times inside
                        if typeSize.isAccessibilitySize { stacked(day) } else { spine(day) }
                        if let q = (day.rows + day.anytime).compactMap({ $0.question }).first {
                            QuestionCard(question: q, store: store, large: false)
                        }
                    } else if let failure = store.failure {
                        Text(failure).font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(.horizontal)
            }
            NewBox(assistantSetUp: false, onAdded: { Task { await store.load() } })
        }
        .task { await store.load() }
    }

    private func rest(_ day: DayAnswer) -> [DayItem] {
        let next = day.simple.next?.id
        let timed = day.rows.filter { $0.kind == "item" && $0.state != "done" && $0.late != true && $0.id != next }
        return timed + day.anytime.filter { $0.state != "done" }
    }

    private func spine(_ day: DayAnswer) -> some View {
        let more = rest(day)
        return VStack(alignment: .leading, spacing: 10) {
            if let n = day.simple.next {
                HStack(alignment: .top, spacing: 8) {
                    timeAndKnot(n.timeText ?? "")
                    nextCard(n)
                }
            }
            if !more.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    timeAndKnot(more.first?.timeText ?? "")
                    todayCard(more)
                }
            } else {
                Text("Nothing else today.").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func stacked(_ day: DayAnswer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let n = day.simple.next { nextCard(n) }
            todayCard(rest(day))
        }
    }

    private func timeAndKnot(_ text: String) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.footnote).bold().multilineTextAlignment(.trailing).frame(width: 56, alignment: .trailing)
            Circle().fill(Color.accentColor).frame(width: 10, height: 10)
        }
        .padding(.top, 18)
        .accessibilityHidden(true)
    }

    private func nextCard(_ n: SimpleNext) -> some View {
        Button(action: openDay) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NEXT").font(.caption).bold().foregroundStyle(.secondary)
                Text(n.title).font(.title).bold()
                Text(n.line.replacingOccurrences(of: #"^At [^,]+, "#, with: "", options: .regularExpression)).font(.subheadline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .bubble(n.color, radius: 26, lift: 7)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel("Next: \(n.title), \(n.line). Opens your day.")
    }

    private func todayCard(_ items: [DayItem]) -> some View {
        // each row its own B1 block: the symbol and the words inside it, no tile
        VStack(spacing: 8) {
            ForEach(items) { r in
                Button(action: openDay) {
                    HStack(spacing: 10) {
                        Image(systemName: organizerSymbol(r.icon)).frame(width: 26)
                        Text(r.title ?? "").font(.body).bold()
                        Spacer(minLength: 0)
                        if let t = r.timeText, !t.isEmpty { Text(t).font(.footnote) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8).frame(minHeight: 44)
                    .bubble(r.color, radius: 18, lift: 4)
                }
                .buttonStyle(BubblePressStyle())
            }
        }
    }
}
