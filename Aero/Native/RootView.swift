import SwiftUI

/// The first screen. The app opens on the calendar around today: Day, Week, Month, Year and Lists as underline tabs around one held date, with
/// the box at the bottom on every tab, whether or not a PC is set up (with a server address it asks the PC through Aero's server, without
/// one it uses the phone's own records; OrganizerBackends). The screens do not know which they have. What is not drawn natively yet (an item's
/// own screen, a Colony event, the PC's lists and the rest of Aero) opens in the web view when a PC is set up; with none, the
/// header's menu has a row to connect a PC, which opens the web view's first-launch screen where the address is asked for. The system's
/// navigation bar is not used: each screen draws its own header, as the mocks do.
///
/// (Before 2026-10-16 the first screen was a today-only home with the calendar one tap away in a menu; the first TestFlight build showed that
/// a person did not find it: "there's also no other view in the app". OrganizerHomeScreen is still in the project, not shown.)
///
/// Chat (a Chat tab beside Lists, with a PC set up) is drawn natively by `ChatScreen` and comes in over the calendar as a page.
///
/// What is not here yet: opening one particular item or event in the web view. `WebViewController` opens the server's address; moving it
/// to an item's own screen needs a way to give it a path, which it does not have. Until then a tap on an item opens Aero's own front in the
/// web view, from which the item is one tap.
struct RootView: View {
    @State private var showWeb = false
    @State private var showChat = false
    @State private var webClosed = 0
    @State private var hasAddress = AppInfo.address != nil
    @State private var ready = !DemoMode.isOn
    @Environment(\.scenePhase) private var scenePhase

    private func setChat(_ on: Bool) {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { showChat = on }
    }

    /// The Chat tab on the calendar: only with a PC set up, since chats are kept and answered there.
    private var chatOpener: (() -> Void)? {
        hasAddress ? { setChat(true) } : nil
    }

    var body: some View {
        Group {
            if !ready {
                ProgressView()
            } else {
                ZStack {
                    NavigationStack {
                        OrganizerDayScreen(open: { _ in if hasAddress { showWeb = true } },
                                           openLists: { if hasAddress { showWeb = true } },
                                           openChat: chatOpener,
                                           menuTitle: hasAddress ? "More" : "Connect your PC",
                                           menuAction: { showWeb = true })
                            .id(hasAddress)      // a new set of stores when a PC is set up or removed
                    }
                    // Chat is a page that comes in over the calendar and goes back the same way; the web view is where Face ID unlocks Locked
                    if showChat && hasAddress {
                        ChatScreen(back: { setChat(false) },
                                   unlock: { showWeb = true },
                                   returned: webClosed)
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
                .fullScreenCover(isPresented: $showWeb, onDismiss: { webClosed += 1 }) {
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
