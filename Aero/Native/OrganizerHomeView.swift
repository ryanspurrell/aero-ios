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
        let rtl = UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft
        guard let day = store.answer?.day, let id = TieOrder.firstNext(day.simple, rightToLeft: rtl), let row = day.rows.first(where: { $0.id == id }) else { return }
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
            // the quiet rows (where a thing went or was due) are the day view's: they are neither "something else today" nor a reason to say so
            if day.simple.later.isEmpty && !day.anytime.contains(where: { !Pointer.isQuiet($0.state) }) && day.simple.next != nil {
                Text("Nothing else today.").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            if let waiting = (day.rows + day.anytime).first(where: { $0.question != nil }) {
                PointerView(pointer: Pointer(waiting), size: .question, actions: .day(store, open: { _ in openDay() }))
            }
            let extras = HomeExtrasSource.current()
            if let carry = extras.carryOn {
                PointerView(pointer: Pointer(owner: "carryon", id: "carryon", title: carry, colorValue: "green", label: "Carry on"), size: .card)
            }
            if !extras.keys.isEmpty {
                HStack(spacing: Look.Space.snug) { ForEach(extras.keys) { PointerView(pointer: Pointer($0), size: .key) } }
            }
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

