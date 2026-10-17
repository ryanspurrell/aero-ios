import Foundation

// What Aero's chat routes answer, and the plain rules the screen follows (what a chat is called, what is drawn on which side, when to stop
// asking for a reply). The shapes are those of aero_web.py (`rooms_list`, `room_get`, `room_new`, `room_send`) and of the store's `rooms_of`,
// `room` and `messages` (fingus_messages_store.py); every field is optional where the server may leave it out.

// MARK: privacy, chosen before anything is said

/// Open or Locked (Aryn, 2026-10-13: Private is called Locked). Chosen in the start flow, never changed after: a chat is made as one or the other.
enum ChatPrivacy: String, CaseIterable, Identifiable, Equatable {
    case open, locked
    var id: String { rawValue }
    var title: String { self == .open ? "Open" : "Locked" }

    /// Where it is kept and who answers: the words the page itself uses under "Who sees this" (messages.js, roomWhoSheet).
    var line: String {
        self == .open ? "Kept on your PC and the phones in it" : "Kept on your PC, Locked. Answers on your PC; nothing leaves it"
    }
}

// MARK: wire shapes

struct ChatMember: Codable, Equatable {
    var kind: String
    var name: String
    var nick: String?
    var model: String?
}

/// One row of GET /rooms.json.
struct ChatRoomRow: Codable, Identifiable, Equatable {
    var id: String
    var name: String?
    var direct: Bool?
    var pinned: Bool?
    var touched: Double?
    var last: Int?
    var unread: Int?
    var epoch: Int?
    var ai: Bool?
    var isLocked: Bool?
    var members: [ChatMember]?
    var closed: String?
    enum CodingKeys: String, CodingKey { case id, name, direct, pinned, touched, last, unread, epoch, ai, members, closed; case isLocked = "private" }

    var locked: Bool { isLocked ?? false }
}

/// GET /rooms.json: who this is (`me` is the account's name, `me_id` the person id keys are bound to) and the rooms.
struct ChatRoomsAnswer: Codable, Equatable {
    var me: String
    var meID: String?
    var rooms: [ChatRoomRow]
    enum CodingKeys: String, CodingKey { case me, rooms; case meID = "me_id" }

    /// The id the keys and signatures are bound to: `me_id` where the server gives one, otherwise the name (the page does the same).
    var person: String { meID ?? me }
}

/// A device's public keys, as GET /devices.json and a room answer's `devices` list them.
struct ChatDeviceInfo: Codable, Equatable {
    var device: String
    var ecdh: String
    var sign: String
    var label: String?
    var personID: String?
    var isPrivate: Bool?
    enum CodingKeys: String, CodingKey { case device, ecdh, sign, label; case personID = "person_id"; case isPrivate = "private" }

    init(device: String, ecdh: String, sign: String, label: String? = nil, personID: String? = nil, isPrivate: Bool? = nil) {
        self.device = device; self.ecdh = ecdh; self.sign = sign; self.label = label; self.personID = personID; self.isPrivate = isPrivate
    }

    /// The store keeps `private` as 0 or 1, so a number is read as well as true and false.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = try c.decode(String.self, forKey: .device)
        ecdh = try c.decode(String.self, forKey: .ecdh)
        sign = try c.decode(String.self, forKey: .sign)
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        personID = try? c.decodeIfPresent(String.self, forKey: .personID)
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .isPrivate) {
            isPrivate = b
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .isPrivate) {
            isPrivate = n != 0
        } else {
            isPrivate = nil
        }
    }
}

/// One message as stored: sealed. `sender_id` is the person id the signature is bound to, where the sender is a person.
struct ChatWireMessage: Codable, Equatable {
    var seq: Int
    var kind: String
    var sender: String
    var senderID: String?
    var device: String?
    var at: Double?
    var epoch: Int?
    var iv: String?
    var ct: String?
    var sig: String?
    var note: String?
    enum CodingKeys: String, CodingKey { case seq, kind, sender, device, at, epoch, iv, ct, sig, note; case senderID = "sender_id" }
}

/// A reply being written now, as far as it has got (`writing` in GET /rooms/<id>.json, the same words the page draws as a reply streams in).
struct ChatWriting: Codable, Equatable {
    var name: String
    var text: String?
    var stage: String?
}

/// GET /rooms/<id>.json?device=<id>&after=<seq>.
struct ChatRoomAnswer: Codable, Equatable {
    var id: String
    var name: String?
    var epoch: Int
    var ai: Bool?
    var isLocked: Bool?
    var members: [ChatMember]
    var messages: [ChatWireMessage]
    var seals: [ChatSeal]
    var devices: [String: [ChatDeviceInfo]]
    var holders: [String: String]?
    var writing: [ChatWriting]?
    var me: String?
    enum CodingKeys: String, CodingKey { case id, name, epoch, ai, members, messages, seals, devices, holders, writing, me; case isLocked = "private" }

    var locked: Bool { isLocked ?? false }
}

// MARK: the lines on the screen

/// A message opened (or not): what the screen draws. `text` is nil for a reaction or a body without words, which draw nothing.
struct ChatEntry: Equatable {
    var seq: Int
    var kind: String
    var sender: String
    var text: String?
    var note: String?
    var at: Double?
    /// Why it could not be opened, in words: "Sent before you joined", "This message couldn't be verified".
    var unreadable: String?
}

struct ChatLine: Identifiable, Equatable {
    enum Side: Equatable { case mine, theirs, note }
    var id: String
    var side: Side
    var speaker: String?
    var text: String
    var at: Double?
    var streaming: Bool
    var unreadable: Bool
}

enum ChatTranscript {
    /// The lines in order: your words on one side, replies on the other, the room's own notes between. A reply still being written is the last
    /// line, drawn as far as it has got; it is dropped once the finished reply (the same words) is among the entries, so it is never shown twice.
    static func lines(entries: [ChatEntry], me: String, writing: [ChatWriting], showSpeakers: Bool, shown: (String) -> String) -> [ChatLine] {
        var out: [ChatLine] = []
        for e in entries {
            if e.kind == "note" {
                if let note = e.note, !note.isEmpty { out.append(ChatLine(id: "m\(e.seq)", side: .note, speaker: nil, text: note, at: e.at, streaming: false, unreadable: false)) }
                continue
            }
            let words = e.unreadable ?? e.text
            guard let words, !words.isEmpty else { continue }
            let mine = e.kind == "person" && e.sender == me
            out.append(ChatLine(id: "m\(e.seq)", side: mine ? .mine : .theirs, speaker: (!mine && (showSpeakers || e.kind == "person")) ? shown(e.sender) : nil,
                                text: words, at: e.at, streaming: false, unreadable: e.unreadable != nil))
        }
        let lastReply = out.last(where: { $0.side == .theirs })?.text
        for w in writing {
            let text = (w.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty, text == lastReply { continue }
            out.append(ChatLine(id: "writing-\(w.name)", side: .theirs, speaker: showSpeakers ? shown(w.name) : nil, text: text, at: nil, streaming: true, unreadable: false))
        }
        return out
    }
}

// MARK: the list

enum ChatListing {
    /// What a chat is called: its own name, else the others in it (a name they set for themselves in the chat, else their account's), else "Just you".
    static func title(_ room: ChatRoomRow, me: String) -> String {
        if let name = room.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let others = (room.members ?? []).filter { !($0.kind == "person" && $0.name == me) }.map { shownName($0) }
        return others.isEmpty ? "Just you" : others.joined(separator: ", ")
    }

    static func shownName(_ m: ChatMember) -> String {
        if let nick = m.nick, !nick.isEmpty { return nick }
        guard let first = m.name.first else { return m.name }
        return first.uppercased() + m.name.dropFirst()
    }

    /// Pinned first, then as the server ordered them (newest first). A Locked chat is left out unless Locked is open.
    static func order(_ rooms: [ChatRoomRow], lockedOpen: Bool) -> [ChatRoomRow] {
        let shown = rooms.filter { lockedOpen || !$0.locked }
        return shown.filter { $0.pinned == true } + shown.filter { $0.pinned != true }
    }

    /// "3 new", or nothing when all is read.
    static func unreadWords(_ room: ChatRoomRow) -> String? {
        guard let n = room.unread, n > 0 else { return nil }
        return "\(n) new"
    }
}

// MARK: choosing the model for a new chat

enum ChatModelPick {
    /// The page's own test for a model that runs on this PC (`localModels` in aero_web.py): not "auto", not Claude or Codex, not a cloud tag.
    static func runsOnThePC(_ model: String) -> Bool {
        let lower = model.lowercased()
        if model.hasPrefix("auto") || lower.hasPrefix("claude") || lower.hasPrefix("codex") { return false }
        return !(lower.hasSuffix(":cloud") || lower.hasSuffix("-cloud"))
    }

    /// The first model Aero offers; for a Locked chat, the first that runs on the PC (the page: `here[0]`). nil when there is none.
    static func pick(from models: [String], privacy: ChatPrivacy) -> String? {
        privacy == .locked ? models.first(where: runsOnThePC) : models.first
    }
}

// MARK: waiting for a reply

/// When to keep asking for a reply. The page is pushed each change; the app asks again and again (the interval is picked, not grounded: a
/// reply seems to move at about the pace a person reads, and each ask is one small request).
enum ChatPollPlan {
    static let interval: Double = 0.8
    /// How long to wait for a reply to start before the chat is left quiet. Picked, not grounded: a model that must first load can be slow to begin.
    static let waitForStart: Double = 30

    static func shouldContinue(writing: Bool, busy: Bool, sawReply: Bool, secondsSinceSend: Double) -> Bool {
        if writing || busy { return true }
        if sawReply { return false }
        return secondsSinceSend < waitForStart
    }
}
