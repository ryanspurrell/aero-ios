import Foundation
import SwiftUI

/// The state behind the Shopping screen: what Organizer last said (the things, the lists and what each holds now), which tab is showing, and the
/// changes a person makes (make, rename, change the rules of, remove a list; put a thing in a list by hand and take it out; tick it bought).
/// Organizer is asked after every change; nothing here is kept that it said.
@MainActor
final class ShoppingModel: ObservableObject {
    /// What the sheet over the screen is.
    enum Sheet: Identifiable, Equatable {
        case make, own, edit(String), item(String)
        var id: String {
            switch self {
            case .make: return "make"
            case .own: return "own"
            case .edit(let id): return "edit-" + id
            case .item(let id): return "item-" + id
            }
        }
    }

    @Published private(set) var snap = ShopSnapshot()
    @Published private(set) var loaded = false
    /// The tab: empty is All.
    @Published var listId = ""
    /// What stopped, in the one shape (StopWords), with Doctor's id of its kind for Find out why.
    @Published private(set) var failure: StopLine?
    @Published var sheet: Sheet?
    /// A short quiet confirmation ("List removed. Nothing on it was deleted.").
    @Published private(set) var note: String?

    let backend: ShoppingBackend

    /// The PC when one is set up, otherwise the phone's own records; the screen does not know which.
    init(backend: ShoppingBackend = ShoppingBackends.current()) {
        self.backend = backend
    }

    var shown: [ShopThing] { ShopView.things(snap, listId: listId) }
    var chosenList: ShopList? { snap.lists.first { $0.id == listId } }
    func list(_ id: String) -> ShopList? { snap.lists.first { $0.id == id } }
    func thing(_ id: String) -> ShopThing? { snap.things.first { $0.id == id } }

    func load() async {
        do {
            snap = try await backend.load()
            listId = ShopView.settled(listId, in: snap)
            failure = nil
        } catch {
            failure = StopWords.line(doing: "Showing your shopping", backend: backend.kind, error: error)
        }
        loaded = true
    }

    /// The words Organizer or the rules gave for a refusal, to show as they are; nil when the failure was not an answer (the way to it).
    static func said(_ error: Error) -> String? {
        if let r = error as? Refusal { return r.words }
        if let f = error as? OrganizerAPI.Failure, case .server(let words) = f { return words }
        return nil
    }

    /// Runs one change; returns the words to show when it did not go (a refusal's own, or the one-shape line), nil when it did. The screen is
    /// read again after a change that went.
    private func change(_ doing: String, _ run: () async throws -> Void) async -> String? {
        do {
            try await run()
            failure = nil
            await load()
            return nil
        } catch {
            if let words = Self.said(error) { return words }
            let line = StopWords.line(doing: doing, backend: backend.kind, error: error)
            failure = line
            return line.text
        }
    }

    func choose(_ id: String) {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { listId = id }
    }

    /// Make the list Organizer offered, as offered (nothing is made until it is tapped).
    func make(_ offer: ShopOffer) async -> String? {
        var made = ""
        let words = await change("Making the list") { made = try await backend.save(id: nil, name: offer.name, filter: offer.filter.json) }
        if words == nil { listId = made; sheet = nil; note = "List made" }
        return words
    }

    /// Save a draft: a new list (`editing` nil) or the changes to one. A rule too tangled to edit here is kept as it is.
    func save(_ draft: ShopDraft, editing: ShopList?) async -> String? {
        if let problem = draft.problem { return problem }
        let rule = draft.filter(id: editing?.id)?.json ?? editing?.rawFilter ?? ShopFilter.member(ShopFilter.selfSet).json
        var made = ""
        let words = await change("Saving the list") { made = try await backend.save(id: editing?.id, name: draft.name, filter: rule) }
        if words == nil { listId = made; sheet = nil; note = "Saved" }
        return words
    }

    func remove(_ list: ShopList) async -> String? {
        let words = await change("Removing the list") { try await backend.remove(id: list.id) }
        if words == nil {
            if listId == list.id { listId = "" }
            sheet = nil
            note = "List removed. Nothing on it was deleted."
        }
        return words
    }

    func standing(of thing: ShopThing) async -> [ShopStanding]? {
        do { return try await backend.standing(of: thing.id) }
        catch {
            failure = StopWords.line(doing: "Reading its lists", backend: backend.kind, error: error)
            return nil
        }
    }

    func put(_ thing: ShopThing, in list: ShopStanding) async -> String? {
        await change("Adding to the list") { try await backend.put(list: list.id, thing: thing.id) }
    }

    func take(_ thing: ShopThing, from list: ShopStanding) async -> String? {
        await change("Taking it out of the list") { try await backend.take(list: list.id, thing: thing.id) }
    }

    func bought(_ thing: ShopThing) async {
        _ = await change("Marking it bought") { try await backend.bought(thing.id) }
    }

    func clearNote() { note = nil }
}
