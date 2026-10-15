import SwiftUI

/// Where the front can lead. Each is a screen drawn from a board the server sends.
enum Route: Hashable {
    case quickAdd
    case chats
}

/// The native app's one navigation stack: the front, then what it points at.
/// Not yet reached from the normal launch (there is no sign-in step to get a
/// device token); `AeroApp` shows it when launched with `-aero-screen <name>`.
struct NativeRoot: View {
    let source: AeroSource
    @State private var path: [Route]

    init(source: AeroSource, start: [Route] = []) {
        self.source = source
        _path = State(initialValue: start)
    }

    var body: some View {
        NavigationStack(path: $path) {
            FrontView(source: source, onTalk: {})
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .quickAdd: QuickAddView(source: source)
                    case .chats: ChatListView(source: source)
                    }
                }
        }
    }
}
