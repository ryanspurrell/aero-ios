import SwiftUI

enum FieldTab: String { case board, trip, custody, situation, report }

/// The five pages of the app as tabs along the bottom, where a thumb reaches them. The same on iPhone and iPad.
struct FieldRoot: View {
    @ObservedObject private var store: FieldStore
    @State private var tab: FieldTab
    private let initialSheet: BoardView.Sheet?

    init(store: FieldStore, tab: FieldTab = .board, initialSheet: BoardView.Sheet? = nil) {
        self.store = store
        _tab = State(initialValue: tab)
        self.initialSheet = initialSheet
    }

    var body: some View {
        TabView(selection: $tab) {
            BoardView(initialSheet: initialSheet)
                .tabItem { Label("Board", systemImage: "square.grid.2x2") }.tag(FieldTab.board)
            TripView()
                .tabItem { Label("Trip", systemImage: "figure.stairs") }.tag(FieldTab.trip)
            CustodyView()
                .tabItem { Label("Custody", systemImage: "doc.text") }.tag(FieldTab.custody)
            SituationListView()
                .tabItem { Label("Try", systemImage: "lightbulb") }.tag(FieldTab.situation)
            TicketView()
                .tabItem { Label("Report", systemImage: "text.bubble") }.tag(FieldTab.report)
        }
        .tint(Look.Palette.fg)
        .environmentObject(store)
    }
}
