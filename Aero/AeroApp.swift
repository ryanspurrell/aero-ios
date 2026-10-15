import SwiftUI

@main
struct AeroApp: App {
    var body: some Scene {
        WindowGroup {
            if let screen = UserDefaults.standard.string(forKey: "aero-screen") {
                // Drawing the native screens from invented samples, for screenshots:
                // launch with `-aero-screen front`, `quickadd` or `chats`. No server.
                NativeRoot(source: SampleSource(), start: screen == "quickadd" ? [.quickAdd] : screen == "chats" ? [.chats] : [])
            } else {
                WebScreen()
                    .ignoresSafeArea()
                    .background(Color(red: 0.06, green: 0.10, blue: 0.11))
            }
        }
    }
}

/// Holds the view controller that owns the web view.
struct WebScreen: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> WebViewController {
        WebViewController()
    }

    func updateUIViewController(_ controller: WebViewController, context: Context) {}
}
