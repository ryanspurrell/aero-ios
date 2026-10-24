import Foundation

// This file mirrors Part A to Part E and Part G of FieldSample.lean (projects/foundations/FingusFoundations/FingusFoundations/Systems/FieldSample.lean),
// name by name. Each doc comment says which Lean definition or theorem the Swift one answers to. Natural numbers of the Lean file are `Int` here,
// kept at 0 or above by `monus` where Lean's subtraction would stop at 0. Nothing here reads a clock, a place or a network: every rule is a value
// function, as in the Lean file.
//
// WHERE IT LIVES AND WHY (standing rule 29). The principles (projects/core/design__core_principles_2026-10-09.md): Core is a translation layer, not a
// database; every part works without the rest (rule 17). The Field app is its own app, "a separate app in app store, displaying a board" (Aryn,
// 2026-10-23, 4:08 pm; "An app is a board of boards", projects/fingusfacts/design__boards_as_pages_2026-10-06.md). It owns all of its code and
// stores its records in one file on the device; Core is not involved, so with no Core and no network it serves one person on one phone, which is
// the standalone case the Lean file states. Shared with Aero are only the look (Aero/Native/Tokens.swift and FingusUI.swift, referenced by path from
// project.yml, not copied). Nothing here is AI and nothing goes through Relay (deterministic first, rule 22). Cross-platform (rule 30): the rules in
// this folder use only Foundation values (`Model/`), so another front end can use them; the SwiftUI screens are the iOS plug-in.

/// FourContainment.Four: yes, no, all (told both ways), none (told neither). One record never reads "all" (`toFour_ne_all`).
enum Four: String, Codable, CaseIterable { case yes, no, all, none }

/// `Nat` subtraction: a time or count taken from a later one stops at 0, as `e - s.start` does in Lean.
func monus(_ a: Int, _ b: Int) -> Int { max(0, a - b) }

/// Lean `Sample`. Times are whole minutes; flows are exact; `stop == nil` while the pump runs; `after == nil` until the flow is measured after the
/// run; `height` (cm above the floor) is nil when not known.
struct Sample: Hashable, Codable, Identifiable {
    var id: Int
    var pump: Int
    var place: String
    var start: Int
    var stop: Int?
    var before: Rat
    var after: Rat?
    var height: Int?
}

/// Lean `Method`: the flow band `[lo, hi]`, the largest allowed difference `tol` between the flow before and after (L/min), the required volume
/// `minVol` (L).
struct Method: Hashable, Codable {
    var lo: Rat
    var hi: Rat
    var tol: Rat
    var minVol: Rat

    /// Lean `method7400`: band 0.5 to 16 L/min and 400 L are grounded (the research note on NIOSH 7400); the 1/10 L/min allowed difference is
    /// PICKED, NOT GROUNDED (the Lean file says so, and the app says so on its "About the numbers" page).
    static let method7400 = Method(lo: Rat(1, 2), hi: 16, tol: Rat(1, 10), minVol: 400)
}

/// Lean `volume`: the mean of the flow before and the flow after, times the run time in minutes. The method's convention, not physics.
/// (`volume_zero_time`, `volume_mono_time`, `volume_mono_before`, `volume_mono_after`.)
func volume(_ b: Rat, _ a: Rat, _ t: Int) -> Rat { (b + a) / 2 * Rat(t) }

/// Lean `Check`: the checks a finished sample can fail.
enum Check: Hashable, Codable {
    case timesOrder, beforeOutOfBand, afterOutOfBand, drift, volumeShort

    /// Lean `Check.all`: the order the checks are looked at; the first failing one is the one named (`Check.mem_all`).
    static let all: [Check] = [.timesOrder, .beforeOutOfBand, .afterOutOfBand, .drift, .volumeShort]
}

/// Lean `Wait`: why a sample cannot be read yet.
enum Wait: Hashable, Codable { case running, afterMissing }

/// Lean `State` (named SampleState here so it does not hide SwiftUI's @State): counts; fails naming the check; not yet, naming what is missing.
enum SampleState: Hashable { case counts, fails(Check), notYet(Wait) }

/// Lean `failedB`: does check `c` fail, for a sample stopped at `e` with after-flow `a`?
func failedB(_ m: Method, _ s: Sample, _ e: Int, _ a: Rat, _ c: Check) -> Bool {
    switch c {
    case .timesOrder: return e < s.start
    case .beforeOutOfBand: return s.before < m.lo || m.hi < s.before
    case .afterOutOfBand: return a < m.lo || m.hi < a
    case .drift: return m.tol < (s.before - a).magnitude
    case .volumeShort: return volume(s.before, a, monus(e, s.start)) < m.minVol
    }
}

/// Lean `verdict`: the first failing check is named, or the sample counts. (`verdict_counts_iff`.)
func verdict(_ m: Method, _ s: Sample, _ e: Int, _ a: Rat) -> SampleState {
    if let c = Check.all.first(where: { failedB(m, s, e, a, $0) }) { return .fails(c) }
    return .counts
}

/// Lean `state`: running is "not yet (running)"; stopped without an after-flow is "not yet (after missing)"; otherwise the verdict.
/// (`state_running`, `state_afterMissing`, `state_complete`, `state_counts_iff`.)
func state(_ m: Method, _ s: Sample) -> SampleState {
    switch (s.stop, s.after) {
    case (nil, _): return .notYet(.running)
    case (.some, nil): return .notYet(.afterMissing)
    case let (e?, a?): return verdict(m, s, e, a)
    }
}

/// Lean `toFour`: counts is yes, a failed check is no, something still missing is none. Never all (`toFour_ne_all`); a running sample and a
/// sample with its after-flow missing are never yes (`running_not_yes`, `afterMissing_not_yes`); a failed check is never yes (`failed_not_yes`).
func toFour(_ s: SampleState) -> Four {
    switch s {
    case .counts: return .yes
    case .fails: return .no
    case .notYet: return .none
    }
}

/// Lean `combine`: two readings of the same sample; where they agree the reading is theirs, where they disagree it is "all". The only place "all"
/// appears (`combine_self`, `combine_eq_all_iff`).
func combine(_ s: SampleState, _ t: SampleState) -> Four { s == t ? toFour(s) : .all }

// MARK: Part D: several pumps in one run

/// Lean `Run`: the samples of one outing.
typealias Run = [Sample]

/// Lean `Distinct`: ids are distinct.
func isDistinct(_ r: Run) -> Bool { Set(r.map(\.id)).count == r.count }

/// Lean `stateOf`: the state of the sample with id `j`, if the run has one (the first with that id, as `List.find?` does).
func stateOf(_ m: Method, _ r: Run, _ j: Int) -> SampleState? { r.first(where: { $0.id == j }).map { state(m, $0) } }

/// Lean `edit`: change the sample with id `i` by `f`, leaving the rest. `f` must keep the id (the Lean hypothesis `hf`), so the app passes only
/// functions that change other fields; `edit_independent` and `edit_ids` then hold.
func edit(_ r: Run, _ i: Int, _ f: (Sample) -> Sample) -> Run {
    r.map { s in
        guard s.id == i else { return s }
        var t = f(s)
        t.id = s.id
        return t
    }
}

/// Lean `stopAt`: stop the sample with id `i` at minute `t` (`stop_independent`, `stop_keeps_distinct`).
func stopAt(_ r: Run, _ i: Int, _ t: Int) -> Run { edit(r, i) { var s = $0; s.stop = t; return s } }

/// Lean `setAfter`: record the after-flow of the sample with id `i` (`setAfter_independent`, `setAfter_keeps_distinct`).
func setAfter(_ r: Run, _ i: Int, _ a: Rat) -> Run { edit(r, i) { var s = $0; s.after = a; return s } }

/// Adding a sample: the Lean `n :: r` (`add_independent`, `add_keeps_distinct`, which needs `n.id` not already in the run). Returns nil, and adds
/// nothing, when the id is already there.
func adding(_ r: Run, _ n: Sample) -> Run? { r.contains(where: { $0.id == n.id }) ? nil : [n] + r }

/// The id a new sample gets: above every id in the run, so it is new (the hypothesis of `add_keeps_distinct`).
func freshId(_ r: Run) -> Int { (r.map(\.id).max() ?? 0) + 1 }

// MARK: Part E: the timer on each card

/// Lean `dueRun`: whole minutes of run needed to reach `minVol` at a planned constant flow. A flow at or below 0 gives 0 (Lean's `ℚ` division and
/// `Nat.ceil`), so the screen shows a stop time only for a flow above 0.
func dueRun(_ minVol: Rat, _ flow: Rat) -> Int { (minVol / flow).ceilNat }

/// Lean `stopDue`: start plus the whole minutes needed. At that minute a run at the planned flow has reached the minimum
/// (`stopDue_meets_minimum`), and one minute earlier it has not (`before_stopDue_short`, `stopDue_run`).
func stopDue(_ start: Int, _ minVol: Rat, _ flow: Rat) -> Int { start + dueRun(minVol, flow) }
