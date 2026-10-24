import Foundation

// Mirrors Part F2 (reach for the trip) of FieldSample.lean: a sample out of reach means a second trip.

/// Lean `Tools`: one entry per ladder or tool; a value is a confirmed (measured) reach in cm, nil is a tool said to exist whose reach nobody has
/// measured. No tools listed is the same as nothing confirmed.
typealias Tools = [Int?]

/// Lean `reachOk`: some tool has a confirmed reach of at least `h`.
func reachOk(_ tools: Tools, _ h: Int) -> Bool { tools.contains { $0.map { h <= $0 } ?? false } }

/// Lean `unknownTool`: some reach is not confirmed, or no tool is listed at all.
func unknownTool(_ tools: Tools) -> Bool { tools.isEmpty || tools.contains { $0 == nil } }

/// Lean `sampleReach`. yes: a confirmed reach is high enough. none: its height is unknown, or no confirmed reach is high enough while some reach is
/// unconfirmed. no: its height is known and every tool is confirmed and too short.
func sampleReach(_ tools: Tools, _ s: Sample) -> Four {
    guard let h = s.height else { return .none }
    if reachOk(tools, h) { return .yes }
    return unknownTool(tools) ? .none : .no
}

/// Lean `Equip`: the trip's equipment check.
enum Equip: Hashable { case ready, cannotReach(Int), unknown }

/// Lean `tripReady`: READY only when every planned sample is reachable; NO naming the first sample that cannot be reached (a shown shortfall
/// counts even if other things are unknown); otherwise unknown. (`ready_iff`, `ready_reachable`, `unknown_height_not_ready`,
/// `unconfirmed_reach_not_ready`, `cannotReach_names`, `ready_mono`.)
func tripReady(_ tools: Tools, _ r: Run) -> Equip {
    if let s = r.first(where: { sampleReach(tools, $0) == .no }) { return .cannotReach(s.id) }
    return r.allSatisfy({ sampleReach(tools, $0) == .yes }) ? .ready : .unknown
}

/// Lean `needed`: the reach the trip needs, the largest planned height (0 if none is known). (`needed_mono`, `needed_ge_height`.)
func needed(_ r: Run) -> Int { r.compactMap(\.height).reduce(0, max) }
