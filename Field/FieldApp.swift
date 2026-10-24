import SwiftUI

// FIELD: a separate app that displays one board, for people who set up several air-sampling pumps in several places and write times and flows on
// paper (Aryn, 2026-10-23, 4:04 to 4:24 pm; ideas__later_2026-10-06.md, "Fingus as work for friends; Fingus Environmental" and its "Added" lines).
//
// WHERE IT LIVES AND WHY (standing rule 29). Read: projects/core/design__core_principles_2026-10-09.md (Core is a translation layer, not a
// database; it stays thin; parts work without the rest), design__per_pointer_consent_2026-10-19.md (nothing is shared without a yes: here nothing
// is shared unless the person taps share), design__conduit_relay_2026-10-15.md (Relay is the AI-only layer: this app has none, its rules are
// deterministic), the privacy ladder (every record is Locked on this device and there is no Open side to move it to), and "Aero is a thin shell with
// features as pluggable blocks owned by domains". Field is its own app, "a separate app in app store, displaying a board" (2026-10-23, 4:08 pm). It
// owns its code and its records (one file on this device); Core is not involved and stores nothing. Standalone case (rule 17): with no Core and no
// network it serves one person on one phone, shares nothing, reaches no other part, and every question only Core could answer (who is asking, did the
// owner allow it) answers none. The rules are in Model/ and mirror projects/foundations/.../Systems/FieldSample.lean name by name (Lean first, rule 15).
// What it shares with Aero is the look: Aero/Native/Tokens.swift and FingusUI.swift, included by path in project.yml.
//
// War-zone question (rule 25): works with no signal (nothing waits on a server); cards and timers keep running on a dying battery because the stop
// time is computed from the clock, not counted; one-handed (keys at the bottom, at least 44 points); screen reader labels on every control, text that
// scales; places are plain labels, never coordinates (no location services); photos are not taken at all; nothing leaves the device unless the person
// taps share; "Erase everything" in Settings removes every record at once. Not yet checked with the people it is for (ask-the-people-at-risk-first).

@main
struct FieldApp: App {
    @StateObject private var store = FieldLaunch.makeStore()

    var body: some Scene {
        WindowGroup {
            FieldLaunch.root(store: store)
        }
    }
}

/// Starting the app. For screenshots in the build, the arguments `-FieldScreen board|trip|custody|situation|report|add|settings` and `-FieldSeed 1`
/// open a page with stand-in data kept in memory only; without them the app starts as a person uses it.
enum FieldLaunch {
    static func makeStore() -> FieldStore {
        if UserDefaults.standard.string(forKey: "FieldSeed") != nil {
            let store = FieldStore()
            store.loadExample()
            return store
        }
        return FieldStore(persistence: FieldPersistence.standard())
    }

    static func root(store: FieldStore) -> FieldRoot {
        let screen = UserDefaults.standard.string(forKey: "FieldScreen") ?? "board"
        let sheet: BoardView.Sheet? = screen == "add" ? .add : (screen == "settings" ? .settings : nil)
        return FieldRoot(store: store, tab: FieldTab(rawValue: screen) ?? .board, initialSheet: sheet)
    }
}
