import SwiftUI

/// The app's first screen, organizer first (the approved mock projects/aero/mockups/ios_home_organizer_first_2026-10-15.html): the date line at
/// the top left; the day as one time spine with Next big in its place and each other thing its own block at its own time; a waiting question
/// answered in place with chips; one Carry on card and the small Chats, Recordings and Assistant keys only when they have something or are set
/// up; and the box pinned at the bottom with its mic key. Any of the day opens the day timeline, which zooms out to week, month and year.
///
/// The data is the day's (`calendar`, span day): Organizer's tasks (the phone's own, or the PC's) and Colony's events, each its owner's. Carry
/// on and the three keys belong to other apps and have no source in the app yet (they wait for the shared pieces), so with no source they are
/// not drawn: nothing here makes up a card.
struct OrganizerHomeScreen: View {
    @StateObject private var store = OrganizerDayStore()
    var openDay: () -> Void = {}
    var open: (OpenRef) -> Void = { _ in }
    /// What the header's menu offers beside the calendar: a row to set up a PC, or to open the rest of Aero.
    var menuTitle = "More"
    var menuAction: () -> Void = {}
    @State private var scrolled = false

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: Look.Space.snug) { content }
                            .padding(.horizontal, Look.Space.gutter)
                            .padding(.top, 4)
                            .padding(.bottom, 120)
                    }
                    .onChange(of: store.answer?.date) { _ in scrollToNext(proxy) }
                    .task { await store.load(); scrollToNext(proxy) }
                }
            }
            NewBox(assistantSetUp: false, onAdded: { Task { await store.load() } })
                .padding(.horizontal, Look.Space.gutter)
                .padding(.bottom, 8)
        }
        .fingusGround()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func scrollToNext(_ proxy: ScrollViewProxy) {
        guard let day = store.answer?.day, let id = day.simple.next?.id, let row = day.rows.first(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { proxy.scrollTo(row.id, anchor: .top) }
    }

    // MARK: header: the date line, and a quiet menu

    private var header: some View {
        HStack(alignment: .center) {
            Text(store.answer?.day?.dateText ?? " ").fx(Look.Size.date, style: .subheadline).foregroundStyle(Look.Palette.soft)
            Spacer()
            Menu {
                Button { openDay() } label: { Label("Calendar", systemImage: "calendar") }
                Button { menuAction() } label: { Label(menuTitle, systemImage: store.backendKind == .phone ? "desktopcomputer" : "ellipsis") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.soft)
                    .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
            }
            .accessibilityLabel("Menu")
        }
        .padding(.horizontal, Look.Space.gutter)
        .padding(.top, 6)
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        if let day = store.answer?.day {
            DayRows(day: day, metrics: .home, bigNext: true, inlineQuestions: false, store: store, open: { _ in openDay() })
            if day.simple.later.isEmpty && day.anytime.isEmpty && day.simple.next != nil {
                Text("Nothing else today.").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            if let q = (day.rows + day.anytime).compactMap({ $0.question }).first {
                QuestionInPlace(question: q, store: store)
            }
            let extras = HomeExtrasSource.current()
            if let carry = extras.carryOn { CarryOnCard(title: carry) }
            if !extras.keys.isEmpty { ExtrasRow(keys: extras.keys) }
        } else if let failure = store.failure {
            Text(failure).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        }
    }
}

// MARK: Carry on and the small keys

/// What the home shows beyond the day: one Carry on card and the small keys. Empty until the app has a source for them.
struct HomeExtras {
    struct Key: Identifiable { var id: String; var letter: String; var name: String; var hue: String; var dot = false }
    var carryOn: String?
    var keys: [Key] = []
}

enum HomeExtrasSource {
    static func current() -> HomeExtras {
        DemoMode.showExtras
            ? HomeExtras(carryOn: "Planning Saturday", keys: [.init(id: "chats", letter: "C", name: "Chats", hue: "green", dot: true),
                                                              .init(id: "rec", letter: "R", name: "Recordings", hue: "accent"),
                                                              .init(id: "ai", letter: "A", name: "Assistant", hue: "purple")])
            : HomeExtras()
    }
}

struct CarryOnCard: View {
    let title: String
    var body: some View {
        HStack(spacing: Look.Space.snug) {
            VStack(alignment: .leading, spacing: 0) {
                Text("CARRY ON").fx(Look.Size.carryLabel, style: .caption1).foregroundStyle(Look.Palette.label)
                Text(title).fx(Look.Size.carryTitle, style: .body).foregroundStyle(Look.Palette.ink)
            }
            Spacer()
            Text("›").font(.system(size: 22)).foregroundStyle(Look.Palette.label)
        }
        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.inset)
        .background {
            let c = Fingus.hue("green")
            RoundedRectangle(cornerRadius: Look.Bubble.radiusCard, style: .continuous)
                .fill(LinearGradient(colors: [c.light, c.base], startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)))
                .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowCard.alpha), radius: Look.Bubble.shadowCard.blur / 2, x: 0, y: Look.Bubble.shadowCard.y)
        }
        .padding(.top, 2)
    }
}

struct ExtrasRow: View {
    let keys: [HomeExtras.Key]
    var body: some View {
        HStack(spacing: Look.Space.snug) {
            ForEach(keys) { k in
                HStack(spacing: Look.Space.tight) {
                    Text(k.letter).fx(TypeToken(size: 13, weight: 800), style: .caption1).foregroundStyle(Look.Palette.ink)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(LinearGradient(colors: [Fingus.hue(k.hue).light, Fingus.hue(k.hue).base], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    Text(k.name).fx(Look.Size.extra, style: .subheadline).foregroundStyle(Look.Palette.fg).lineLimit(1).minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, minHeight: Look.Space.sizeInput + Look.Space.hair)
                .fingusCard(radius: Look.Bubble.radiusExtra)
                .overlay(alignment: .topTrailing) {
                    if k.dot { Circle().fill(Look.Palette.now).frame(width: 12, height: 12).padding(.top, 8).padding(.trailing, 10) }
                }
            }
        }
        .padding(.top, 2)
    }
}
