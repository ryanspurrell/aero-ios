import Foundation

/// Invented sample content, used only to draw the screens for screenshots when the
/// app is launched with `-aero-screen front|quickadd|chats`. No real person, place
/// or address; nothing here comes from any server. Decodable-only types are built
/// from JSON text, the way the server sends them.
enum Fixtures {
    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // A typo in the sample text is a mistake in this file, so stopping is right.
        try! JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static let underway: [UnderwayItem] = [
        UnderwayItem(id: "u1", part: "chat", title: "Planning the weekend", why: "Left in the middle",
                     says: nil, device: nil, left: Date().timeIntervalSince1970 - 7200),
        UnderwayItem(id: "u2", part: "backup", title: "Backup", why: "Stopped: the drive was full",
                     says: nil, device: "Laptop", left: Date().timeIntervalSince1970 - 86400),
    ]

    static let board = decode(OrganizerBoard.self, """
    {"tiles":[{"id":"today","name":"Today","count":3,"why":"open tasks due today or earlier"},
              {"id":"scheduled","name":"Scheduled","count":5,"why":"open tasks that have a time"}],
     "rows":[{"id":"shopping","name":"Shopping list","count":4,"group":"lists"},
             {"id":"p1","name":"Home","count":2,"group":"lists","kind":"list"}]}
    """)

    static let reading = decode(QuickAddReading.self, """
    {"args":{"title":"Water the plants","due":"2026-10-16 21:00"},
     "readings":{"questions":[{"sched":0,"title":"Tonight, which one?","said":"tonight",
       "options":[{"key":"a","label":"Thursday 15 Oct, 9:00 pm"},{"key":"b","label":"Friday 16 Oct, 9:00 pm"}]}]}}
    """)

    static let rooms = decode(RoomsView.self, """
    {"unread":2,
     "rooms":[{"id":"r1","kind":"manager","manager":"fingus","pinned":true,"unread":0,"section":"chats"},
              {"id":"r2","kind":"messages","unread":2,"section":"chats"},
              {"id":"r3","kind":"manager","manager":"fingus","unread":0,"section":"p1"}],
     "sections":[{"id":"chats","kind":"chats","name":"","rooms":["r1","r2"],"unread":2,"folded":false},
                 {"id":"p1","kind":"project","name":"Trip","rooms":["r3"],"unread":0,"folded":false}]}
    """)
}
