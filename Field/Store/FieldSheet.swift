import Foundation

// The chain-of-custody sheet, generated from the cards. Plain text, built only from the records passed in; nothing is read from anywhere else and
// nothing is sent: it is shown on screen and shared only when the person taps share (Part F of FieldSample.lean: handovers in order, times that
// do not go back, `valid_times_sorted`).

enum FieldSheet {
    static func text(method m: Method, run: Run, handovers: [Handover], people: [Person], practice: Bool, generated: Int) -> String {
        var out: [String] = []
        out.append("Chain of custody" + (practice ? " (practice copy)" : ""))
        out.append("Made " + FieldClock.dateTime(generated))
        out.append("")
        out.append("Samples")
        for s in run.sorted(by: { $0.start < $1.start }) {
            let w = FieldWording.words(m, s)
            var line = "Sample \(s.id), pump \(s.pump), \(s.place.isEmpty ? "no place" : s.place)"
            line += ". Start " + FieldClock.dateTime(s.start)
            line += s.stop.map { ". Stop " + FieldClock.dateTime($0) } ?? ". Not stopped"
            line += ". Flow before " + FieldWording.flow(s.before)
            line += s.after.map { ". Flow after " + FieldWording.flow($0) } ?? ". Flow after not measured"
            if let e = s.stop, let a = s.after { line += ". Volume " + FieldWording.litres(volume(s.before, a, monus(e, s.start))) }
            line += ". " + w.headline + ": " + w.detail
            out.append(line)
        }
        if run.isEmpty { out.append("No samples.") }
        out.append("")
        out.append("Handovers")
        for h in handovers {
            out.append(FieldClock.dateTime(h.time) + ": " + FieldWording.name(h.giver, people) + " to " + FieldWording.name(h.taker, people))
        }
        if handovers.isEmpty { out.append("No handovers yet.") }
        out.append(isValid(handovers) ? "The chain is unbroken." : "The chain has a gap.")
        out.append("")
        out.append("Made on this phone from the cards. Not sent anywhere.")
        return out.joined(separator: "\n")
    }
}
