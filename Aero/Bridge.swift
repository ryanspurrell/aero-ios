import WebKit

/// The page's way to ask the app things. In the page:
/// `await window.webkit.messageHandlers.fingus.postMessage({ask: "about"})`.
/// In a browser that object does not exist, so the page can tell the two apart.
/// Step 1 answers one question, "about". Bridges are added here later, one
/// `ask` at a time.
final class Bridge: NSObject, WKScriptMessageHandlerWithReply {
    static let name = "fingus"

    /// Bridges that exist. None yet; each later step adds its name.
    static let bridges: [String] = []

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        // Only Aero's own page may ask, never another site in a frame.
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host.lowercased() == AppInfo.aeroHost else {
            replyHandler(nil, "Not allowed")
            return
        }
        guard let body = message.body as? [String: Any],
              let ask = body["ask"] as? String else {
            replyHandler(nil, "Unknown request")
            return
        }
        switch ask {
        case "about":
            let answer: [String: Any] = [
                "app": "FingusAero",
                "version": AppInfo.version,
                "build": AppInfo.build,
                "bridges": Bridge.bridges,
            ]
            replyHandler(answer, nil)
        default:
            replyHandler(nil, "Unknown request")
        }
    }
}
