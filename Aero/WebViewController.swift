import UIKit
import WebKit

/// Shows the Aero page the server serves, full screen, once an address has
/// been entered. Aero handles its own navigation and safe areas, so this adds
/// neither native swipe gestures nor pull-to-refresh, and does not inset the page.
final class WebViewController: UIViewController {
    private var webView: WKWebView!
    private let failureView = FailureView()
    private let setupView = SetupView()

    // Behind the page while it loads, so there is no white flash.
    private let ground = UIColor(red: 0.06, green: 0.10, blue: 0.11, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = ground

        let configuration = WKWebViewConfiguration()
        // The default store is the persistent one: sign-in cookies stay.
        configuration.websiteDataStore = WKWebsiteDataStore.default()
        configuration.allowsInlineMediaPlayback = true
        // Audio plays without a tap where the page already plays it; video
        // still needs one, as in Safari.
        configuration.mediaTypesRequiringUserActionForPlayback = [.video]
        // Adds "FingusAero/<version>" to the end of the user agent.
        configuration.applicationNameForUserAgent = AppInfo.userAgentToken
        configuration.userContentController.addScriptMessageHandler(
            Bridge(), contentWorld: .page, name: Bridge.name)

        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Aero moves between its own screens itself.
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = ground
        webView.scrollView.backgroundColor = ground
        // The page uses env(safe-area-inset-*) with viewport-fit=cover, so the
        // view runs edge to edge and the page keeps clear of the notch itself.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        #if DEBUG
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        #endif

        failureView.onTryAgain = { [weak self] in self?.load() }
        failureView.onChangeAddress = { [weak self] in self?.showSetup() }
        setupView.onConnected = { [weak self] _ in self?.load() }

        for sub in [webView!, failureView, setupView] as [UIView] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            sub.isHidden = true
            view.addSubview(sub)
            NSLayoutConstraint.activate([
                sub.topAnchor.constraint(equalTo: view.topAnchor),
                sub.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                sub.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                sub.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            ])
        }

        if AppInfo.address == nil {
            showSetup()
        } else {
            load()
        }
    }

    /// Opens the saved address.
    private func load() {
        guard let address = AppInfo.address else {
            showSetup()
            return
        }
        setupView.isHidden = true
        failureView.isHidden = true
        webView.isHidden = false
        webView.load(URLRequest(url: address))
    }

    private func showSetup() {
        setupView.prepare()
        setupView.isHidden = false
        failureView.isHidden = true
    }

    private func showFailure() {
        failureView.isHidden = false
    }
}

extension WebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only moves of the whole page are checked; frames inside the page are not.
        let movesPage = navigationAction.targetFrame?.isMainFrame ?? true
        guard movesPage, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if ["about", "blob", "data"].contains(url.scheme) {
            decisionHandler(.allow)
            return
        }
        if let host = url.host,
           url.scheme == "https",
           AppInfo.staysInApp(host: host, current: webView.url?.host) {
            decisionHandler(.allow)
            return
        }
        // A tapped link to another site, or a mail or phone link, goes to the
        // system. Redirects, form posts and scripts of the page stay in the app,
        // so a sign-in that sends the page to another host and back works.
        if navigationAction.navigationType == .linkActivated || navigationAction.targetFrame == nil {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        failureView.isHidden = true
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handle(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handle(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // iOS ended the page's process to free memory; load it again.
        webView.reload()
    }

    private func handle(_ error: Error) {
        let code = (error as NSError).code
        // A load replaced by another one is not a failure.
        if code == NSURLErrorCancelled { return }
        showFailure()
    }
}

extension WebViewController: WKUIDelegate {
    /// Camera and microphone are granted to the entered host's origin only.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        if origin.protocol == "https", origin.host.lowercased() == AppInfo.aeroHost {
            decisionHandler(.grant)
        } else {
            decisionHandler(.deny)
        }
    }

    /// Links that ask for a new window (target="_blank", window.open).
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if url.scheme == "https", let host = url.host,
           AppInfo.staysInApp(host: host, current: webView.url?.host) {
            webView.load(navigationAction.request)
        } else {
            UIApplication.shared.open(url)
        }
        return nil
    }
}
