import Foundation
import CryptoKit

// How a Done or Skip was shown (Aryn, 2026-10-19: "an observation records how it was shown"): the pointers offered at that moment, each with its
// kind, size and style as tokens (never pixels), its place and order, and which was the main one; and the reader's direction. The layout is kept
// once under its content's id; the observation carries {at, layout, pointer, surface, direction}. Only the presentation, never anything else about
// the person. The PC does the same (organizer_service.py `observation_of`); the ids differ between the two because the surfaces' names do.

struct PointerSpec: Codable, Hashable {
    var id: String
    var kind: String = "button"
    var size: String
    var style: String
    /// What tapping it says about the question ("yes", "no"), so the value is read from the pointer.
    var states: String = ""
    var position: Int
    var order: Int
    var main: Bool
}

struct PresentationLayout: Codable, Hashable {
    var v = 1
    var surface: String
    var pointers: [PointerSpec]

    /// Content-addressed: the same presentation has the same id; a changed size, style, place or order has another.
    var id: String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: (try? e.encode(self)) ?? Data())
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

enum Presentation {
    /// The Next card of the simple view: a large Done (the main one) and a quiet Skip.
    static let nextCard = PresentationLayout(surface: "ios.next", pointers: [
        PointerSpec(id: "done", size: "large", style: "ink", states: "yes", position: 0, order: 0, main: true),
        PointerSpec(id: "skip", size: "quiet", style: "quiet", states: "no", position: 1, order: 1, main: false)])

    /// The version of the program writing the record (so what a faulty version wrote can be found).
    static var writer: String { "aero-ios/" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") }

    /// A fixed screen: shown with probability 1, and says so.
    static let fixedScreen: [String: JSONValue] = ["prob": .number(1), "chosen": .bool(false)]

    // The position of a tap in her own sequence is taken by `PhoneStore.put`, in the same locked step as the write that keeps it.

    static var direction: String { UIApplication.shared.userInterfaceLayoutDirection == .rightToLeft ? "rtl" : "ltr" }

    /// The `presented` argument of a Done or Skip made through `layout`, naming the pointer pressed.
    static func presented(_ layout: PresentationLayout, pointer: String) -> JSONValue {
        let e = JSONEncoder()
        let lay = (try? JSONDecoder().decode(JSONValue.self, from: e.encode(layout))) ?? .null
        var o: [String: JSONValue] = ["surface": .string(layout.surface), "pointer": .string(pointer), "direction": .string(direction), "layout": lay,
                                      "app": .string(writer), "device": .string(UIDevice.current.identifierForVendor.map { String($0.uuidString.prefix(8)).lowercased() } ?? "")]
        o.merge(fixedScreen) { $1 }
        return .object(o)
    }

    /// The layouts kept so far, by id (the phone's own place for them).
    static func keep(_ layout: PresentationLayout, defaults: UserDefaults = .standard) -> String {
        var have = defaults.dictionary(forKey: "organizer.layouts") as? [String: Data] ?? [:]
        if have[layout.id] == nil { have[layout.id] = try? JSONEncoder().encode(layout); defaults.set(have, forKey: "organizer.layouts") }
        return layout.id
    }

    /// The time of an observation: a plain time (older records) or a record's `at`.
    static func obsTime(_ v: JSONValue) -> String? { v.stringValue ?? v.objectValue?["at"]?.stringValue }

    /// The entry for done_ats / skipped_ats: a record when a presentation came with the action, else the plain time.
    static func observation(at: String, presented: JSONValue?, tap: [String: JSONValue]? = nil) -> JSONValue {
        guard let p = presented?.objectValue, let raw = p["layout"],
              let data = try? JSONEncoder().encode(raw), let lay = try? JSONDecoder().decode(PresentationLayout.self, from: data) else {
            guard var t = tap else { return .string(at) }
            t["at"] = .string(at); t["layout"] = .string(""); t["pointer"] = .string(""); t["surface"] = .string(""); t["direction"] = .string("")
            return .object(t)
        }
        let pointer = p["pointer"]?.stringValue ?? ""
        let dir = p["direction"]?.stringValue ?? ""
        var o: [String: JSONValue] = tap ?? [:]
        o["at"] = .string(at); o["layout"] = .string(keep(lay))
        o["pointer"] = .string(lay.pointers.contains { $0.id == pointer } ? pointer : "")
        o["surface"] = .string(lay.surface); o["direction"] = .string(["ltr", "rtl"].contains(dir) ? dir : "")
        return .object(o)
    }
}
