import Foundation

// How far off a combined reading can be. Field never rebuilds a signal from samples; the one place it combines readings is `volume`, the mean of
// the flow before and the flow after, times the minutes. That mean is the rebuild of a flat level (the signal band {0}) from two samples.
//
// Source: BlindSpot.lean section 6 (2026-10-24). `recover_error_le_rowSum`: if every sample is off by at most b, a rebuilt point is off by at most
// b times rowSum, and `rowSum_zero_band` gives rowSum = 1 for the flat-level band {0}. So the mean is off by at most b (never more than the
// worst sample). Section 5 (`recover_error_mean_le`) says the same on average: RMS constant 1. A flow that is not flat folds in at most
// (k - 1) times its leakage (`nearly_band_error_le`); Field has no figure for that, so it is not in the bar.
//
// b is not measured here. It is PICKED from the notes (research__air_sampling_pumps_2026-10-23.md): a CDC evaluation of flow-controlled pumps uses
// plus or minus 5 percent, and one pump maker states 2.5 percent. It is a stand-in for the pump in use, until a calibration record gives its own.

extension Method {
    /// Each flow reading may be off by this share of itself: 5 percent. From the notes' pump evaluation, not from the pump in use.
    static let readingError = Rat(1, 20)
}

/// Lean `b` for a mean of two flows: the larger reading times 5 percent bounds both readings' errors.
func flowReadingBound(_ before: Rat, _ after: Rat) -> Rat {
    Method.readingError * (before < after ? after : before)
}

/// Bound on the mean flow: b times rowSum, with rowSum = 1 (`rowSum_zero_band`). L/min.
func meanFlowError(_ before: Rat, _ after: Rat) -> Rat { flowReadingBound(before, after) * Rat(1) }

/// Bound on the volume: the mean flow's bound times the minutes. Litres.
func volumeError(_ before: Rat, _ after: Rat, _ minutes: Int) -> Rat { meanFlowError(before, after) * Rat(minutes) }

extension Rat {
    /// Rounded UP to a multiple of `step` (a bar is never made smaller by rounding). `step` above 0.
    func roundedUp(to step: Rat) -> Rat {
        let q = self / step
        return Rat(q.ceilNat) * step
    }
}

extension FieldWording {
    /// "about ± 0.2 L/min": rounded up to 0.1.
    static func flowBar(_ e: Rat) -> String { "about ± " + e.roundedUp(to: Rat(1, 10)).text() + " L/min" }
    /// "about ± 20 L": rounded up to a whole litre.
    static func litreBar(_ e: Rat) -> String { "about ± " + e.roundedUp(to: 1).text() + " L" }
}
