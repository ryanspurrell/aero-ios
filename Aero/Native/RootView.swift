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
    @State private var addressText = AppInfo.address?.absoluteString ?? ""
    @State private var ready = !DemoMode.isOn
    @Environment(\.scenePhase) private var scenePhase
    // Parts (slice 1): which parts she added, and the test setting that puts Home first. Off by default (standing rule 31), so the calendar stays first.
    @StateObject private var registry = PartRegistry()
    @AppStorage("FingusAddedParts") private var addedRaw = PartsSelection.encode(PartsSelection.standard)
    @AppStorage("FingusPartsHome") private var partsHome = false
    @State private var showYou = false
    @State private var openAfterYou = false

    private func setChat(_ on: Bool) {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { showChat = on }
    }

    /// The Chat tab on the calendar, always there. Chats are kept and answered on the PC, so with none set up it opens a page saying so,
    /// with the key that connects one (a hidden tab told her nothing, 2026-10-17).
    private var chatOpener: (() -> Void)? {
        { setChat(true) }
    }

    var body: some View {
        Group {
            if !ready {
                ProgressView()
            } else {
                ZStack {
                    if partsHome {
                        PartsHomeScreen(registry: registry, added: PartsSelection.decode(addedRaw), hasPC: hasAddress,
                                        openYou: { showYou = true }, openWeb: { showWeb = true }, webClosed: webClosed)
                    } else {
                    NavigationStack {
                        OrganizerDayScreen(open: { _ in if hasAddress { showWeb = true } },
                                           openLists: { if hasAddress { showWeb = true } },
                                           openChat: chatOpener,
                                           menuTitle: "You",
                                           menuAction: { showYou = true })
                            .id(hasAddress)      // a new set of stores when a PC is set up or removed
                    }
                    }
                    // Chat is a page that comes in over the calendar and goes back the same way; the web view is where Face ID unlocks Locked
                    if showChat && !hasAddress {
                        ChatNeedsPCScreen(back: { setChat(false) }, connect: { setChat(false); showWeb = true })
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                    if showChat && hasAddress {
                        ChatScreen(back: { setChat(false) },
                                   unlock: { showWeb = true },
                                   returned: webClosed)
                            .id(addressText)      // another address is another chat session: nothing of the last one is kept
                            .transition(.move(edge: .trailing))
                            .zIndex(1)
                    }
                }
                .sheet(isPresented: $showYou, onDismiss: {
                    // one cover at a time: the web view opens once You has gone
                    if openAfterYou { openAfterYou = false; showWeb = true }
                }) {
                    YouScreen(registry: registry, addedRaw: $addedRaw, partsHome: $partsHome, hasPC: hasAddress,
                              openAero: { openAfterYou = true; showYou = false }, close: { showYou = false })
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
            await registry.load()
        }
        .onChange(of: scenePhase) { phase in
            // top up the phone's reminders when the app opens: iOS keeps only the nearest 64
            if phase == .active, !hasAddress { Task { await OrganizerBackends.phone.refreshReminders() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            hasAddress = AppInfo.address != nil
            addressText = AppInfo.address?.absoluteString ?? ""
        }
    }
}
