import Foundation

/// The server address, kept on the phone, and the rules about which hosts the
/// web view may stay on. No address is built into the app.
enum AppInfo {
    private static let addressKey = "AeroServerAddress"

    private static func string(_ key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }

    static var version: String { string("CFBundleShortVersionString") ?? "0" }
    static var build: String { string("CFBundleVersion") ?? "0" }

    /// Added to the user agent so the page can tell the app from a browser.
    static var userAgentToken: String { "FingusAero/\(version)" }

    /// What the address field starts with. Empty unless the build sets
    /// AERO_DEFAULT_ADDRESS.
    static var defaultAddress: String { string("AeroDefaultAddress") ?? "" }

    /// The saved address. Not a secret, so UserDefaults.
    static var address: URL? {
        get {
            guard let text = UserDefaults.standard.string(forKey: addressKey) else { return nil }
            return URL(string: text)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.absoluteString, forKey: addressKey)
            } else {
                UserDefaults.standard.removeObject(forKey: addressKey)
            }
        }
    }

    /// The saved address's host. The only host given camera and microphone use.
    static var aeroHost: String? { address?.host?.lowercased() }

    /// The part of a host shared with its sibling hosts: the host without its
    /// first label when it has three or more labels ("app.example.com" gives
    /// "example.com"), otherwise the host itself. An IP address is its own base.
    /// This is an approximation; there is no public suffix list in the app.
    static func familyBase(of host: String) -> String {
        let labels = host.split(separator: ".")
        if labels.count < 3 || labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) || host.contains(":") {
            return host
        }
        return labels.dropFirst().joined(separator: ".")
    }

    /// Whether a page on `host` may be shown inside the app: the entered host,
    /// a host in its family, or the host the web view is already showing.
    static func staysInApp(host: String, current: String?) -> Bool {
        let host = host.lowercased()
        guard let entered = aeroHost else { return false }
        if host == entered || host == current?.lowercased() { return true }
        let base = familyBase(of: entered)
        return host == base || host.hasSuffix("." + base)
    }
}
