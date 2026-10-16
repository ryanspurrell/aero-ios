import SwiftUI

@main
struct AeroApp: App {
    var body: some Scene {
        WindowGroup {
            // The native home first (Native/RootView.swift); the web view still draws everything not drawn natively yet.
            RootView()
                .background(Color(red: 0.06, green: 0.10, blue: 0.11))
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
