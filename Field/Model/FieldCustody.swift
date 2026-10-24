import Foundation

// Mirrors Part F (chain of custody) of FieldSample.lean.

/// Lean `Handover`: who gave, who took, at what minute. People are numbers here as in Lean; the screen keeps a name for each (stand-ins in a
/// practice copy).
struct Handover: Hashable, Codable {
    var giver: Int
    var taker: Int
    var time: Int
}

/// Lean `Link`: two handovers follow each other when the taker is the next giver and time does not go back.
func link(_ a: Handover, _ b: Handover) -> Bool { a.taker == b.giver && a.time <= b.time }

/// Lean `Valid`: each handover follows the one before. (`valid_head_le`, `valid_times_sorted`.)
func isValid(_ c: [Handover]) -> Bool {
    guard c.count >= 2 else { return true }
    for i in 0..<(c.count - 1) where !link(c[i], c[i + 1]) { return false }
    return true
}

/// The times of a valid chain never go back (`valid_times_sorted`: the times are pairwise at most each other).
func timesSorted(_ c: [Handover]) -> Bool {
    for i in 0..<c.count { for j in (i + 1)..<max(c.count, i + 1) where c[i].time > c[j].time { return false } }
    return true
}

/// Why a new handover does not follow the last one (nil when it does). Both parts of `Link`, named.
enum LinkProblem: Hashable { case giverIsNotLastTaker(expected: Int), timeGoesBack(last: Int) }

func linkProblem(after last: Handover?, _ h: Handover) -> LinkProblem? {
    guard let last else { return nil }
    if last.taker != h.giver { return .giverIsNotLastTaker(expected: last.taker) }
    if last.time > h.time { return .timeGoesBack(last: last.time) }
    return nil
}

/// `valid_append`: appending a handover that links to the last one keeps the chain valid; anything else is refused and the chain is not changed.
/// An empty chain accepts any first handover.
func appending(_ c: [Handover], _ h: Handover) -> [Handover]? {
    linkProblem(after: c.last, h) == nil ? c + [h] : nil
}
