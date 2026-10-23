import Foundation

/// A failure line in the one shape (wording_conventions.md, "How Fingus speaks when something stops"): what was being done, which step stopped,
/// and what can be done now. `diagnosis` is Doctor's id for this kind of failure, for the Find out why key.
struct StopLine: Equatable {
    var text: String
    var diagnosis: String
}

enum StopWords {
    /// 5xx answers that are the way to Aero saying nothing (Cloudflare's, the tunnel's), not Aero's own: 500 is Aero's own unhandled error.
    static func isEdge(_ status: Int) -> Bool {
        status == 502 || status == 503 || status == 504 || (520...530).contains(status)
    }

    static func shape(_ doing: String, _ step: String, said: String? = nil, next: String = "", _ diagnosis: String) -> StopLine {
        let aero = said.map { " Your PC said \u{201C}\($0)\u{201D}." } ?? ""
        let tail = next.isEmpty ? "" : " " + next
        return StopLine(text: "\(doing) stopped at \(step).\(aero)\(tail)", diagnosis: diagnosis)
    }

    /// The line for an error of an Organizer call: the phone's own records, or the PC through Aero.
    static func line(doing: String, backend: BackendKind, error: Error) -> StopLine {
        guard backend == .pc else { return shape(doing, "reading your records", "other") }
        if let f = error as? OrganizerAPI.Failure {
            switch f {
            case .notReached: return shape(doing, "reaching your PC", "pc_unreachable")
            case .status(let code):
                return isEdge(code) ? shape(doing, "reaching your PC", "pc_unreachable") : shape(doing, "your PC's answer", "other")
            case .notSignedIn: return shape(doing, "signing in", next: "Open Aero to sign in, then try again.", "other")
            case .noAddress: return shape(doing, "finding your PC's address", next: "Connect your PC from the menu.", "other")
            case .server(let words): return shape(doing, "your PC's answer", said: words, "other")
            case .unreadable: return shape(doing, "reading your PC's answer", "other")
            }
        }
        if error is URLError { return shape(doing, "reaching your PC", "pc_unreachable") }
        return shape(doing, "your PC's answer", "other")
    }
}
