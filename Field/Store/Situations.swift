import Foundation

/// "Try a situation": a past or typical job set up and walked through, to see whether the app would have helped (Aryn, 2026-10-23, 4:20 pm). The
/// ladder trip is the first example, in stand-in names. It uses the same reach rules as "Before the trip" (`tripReady`, `sampleReach`, `needed`).
struct Scenario: Hashable {
    var label: String
    var tools: [ToolEntry]
}

struct Situation: Hashable, Identifiable {
    var id: String
    var title: String
    var story: String
    var plan: Run
    var scenarios: [Scenario]
}

enum Situations {
    /// A long drive, a sample too high, a ladder that was said to exist and was too short, and the trip repeated the next week (her friend's
    /// trip as Aryn told it, with the place, client and distance left out).
    static let ladderTrip = Situation(
        id: "ladder-trip",
        title: "The ladder trip",
        story: "A long drive to Site B. One sample is high up. The client said they had a ladder. It was too short, nobody nearby could rent one, and the trip was repeated the next week.",
        plan: [
            Sample(id: 1, pump: 1, place: "Site B, Room 101, sill", start: 0, stop: nil, before: 2, after: nil, height: 90),
            Sample(id: 2, pump: 2, place: "Site B, Room 205, vent", start: 0, stop: nil, before: 2, after: nil, height: 240),
            Sample(id: 3, pump: 3, place: "Site B, Attic hatch", start: 0, stop: nil, before: 2, after: nil, height: 310),
        ],
        scenarios: [
            Scenario(label: "Client says they have one", tools: [ToolEntry(id: 1, name: "Client's ladder", reach: nil)]),
            Scenario(label: "It measures 200 cm", tools: [ToolEntry(id: 1, name: "Client's ladder", reach: 200)]),
            Scenario(label: "Bring a 350 cm one too", tools: [ToolEntry(id: 1, name: "Client's ladder", reach: 200), ToolEntry(id: 2, name: "Our ladder", reach: 350)]),
        ])

    static let all = [ladderTrip]
}
