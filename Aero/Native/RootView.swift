import SwiftUI

/// The first screen. The app opens on the native home, organizer first, whether or not a PC is set up: with a server address it asks the
/// PC (through Aero's server), without one it uses the phone's own records (OrganizerBackends). The home opens the day (which zooms out to
/// week, month and year); the screens do not know which they have. What is not drawn natively yet (an item's own screen, a Colony event,
/// the lists, the chats and the rest of Aero) opens in the web view when a PC is set up; with none, the header's menu has a row to connect a
/// PC, which opens the web view's first-launch screen where the address is asked for. The system's navigation bar is not used: each screen
/// draws its own header, as the mocks do.
///
/// What is not here yet: opening one particular item or event in the web view. `WebViewController` opens the server's address; moving it
/// to an item's own screen needs a way to give it a path, which it does not have. Until then a tap on an item opens Aero's own front in the
/// web view, from which the item is one tap.
struct RootView: View {
    @State private var showWeb = false
    @State private var showDay = DemoMode.isOn && DemoMode.screen != nil
    @State private var hasAddress = AppInfo.address != nil
    @State private var ready = !DemoMode.isOn
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if !ready {
                ProgressView()
            } else {
                NavigationStack {
                    OrganizerHomeScreen(openDay: { showDay = true },
                                        open: { _ in if hasAddress { showWeb = true } },
                                        menuTitle: hasAddress ? "More" : "Connect a PC",
                                        menuAction: { showWeb = true })
                        .id(hasAddress)      // a new set of stores when a PC is set up or removed
                        .navigationDestination(isPresented: $showDay) {
                            OrganizerDayScreen(open: { _ in if hasAddress { showWeb = true } },
                                               openLists: { if hasAddress { showWeb = true } },
                                               back: { showDay = false })
                                .id(hasAddress)
                        }
                }
                .fullScreenCover(isPresented: $showWeb) {
                    ZStack(alignment: .topTrailing) {
                        WebScreen().ignoresSafeArea()
                        Button("Close") { showWeb = false }.padding().buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .fingusGround()
        .task {
            await DemoMode.prepare()
            ready = true
        }
        .onChange(of: scenePhase) { phase in
            // top up the phone's reminders when the app opens: iOS keeps only the nearest 64
            if phase == .active, !hasAddress { Task { await OrganizerBackends.phone.refreshReminders() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            hasAddress = AppInfo.address != nil
        }
    }
}
