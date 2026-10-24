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

/// A reply being written now, as the room route lists it: never its words as text. `live` is the words so far sealed with the room's key (the
/// same shape as the page's live draft: AES-GCM, additional data "room|epoch|sender|device", not signed), absent when there are none or the PC
/// cannot seal them; `stage` is a plain mark of what it is doing.
struct ChatLiveWire: Codable, Equatable {
    var room: String?
    var sender: String
    var device: String
    var epoch: Int
    var iv: String
    var ct: String
}

struct ChatWritingWire: Codable, Equatable {
    var name: String
    var live: ChatLiveWire?
    var stage: String?
}

/// A reply being written, as drawn: `text` is only what was opened and authenticated from `live` (nil when nothing could be opened).
struct ChatWriting: Equatable {
    var name: String
    var text: String?
    var stage: String?
}

/// GET /rooms/<id>.json?device=<id>&after=<seq>.
/// One key sealed to a device, by room and epoch and nothing else of the room: a row of Aero's `devices/keys.json`, listed whether or not the
/// room is shown in the list (a Locked room is not while Locked is shut).
struct ChatHeldKey: Codable, Equatable {
    var room: String
    var epoch: Int
    var byPerson: String
    var byDevice: String
    var iv: String
    var ct: String
    enum CodingKeys: String, CodingKey { case room, epoch, iv, ct; case byPerson = "by_person"; case byDevice = "by_device" }
    var seal: ChatSeal { ChatSeal(epoch: epoch, byPerson: byPerson, byDevice: byDevice, iv: iv, ct: ct) }
}

/// Every key sealed to one device, with the public keys of the devices that sealed them (`devices/keys.json`).
struct ChatHeldKeys: Codable, Equatable {
    var keys: [ChatHeldKey]
    var devices: [String: [ChatDeviceInfo]]
}

/// A device's word that it opened its seal for one room and epoch, as `devices/proofs` takes it (see `ChatRenewalCheck.prove`).
struct ChatOpenedProof: Codable, Equatable {
    var room: String
    var epoch: Int
    var kc: String
    var sig: String
}

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
    /// The public keys of devices removed since, only to open a key one of them sealed and to check a message one signed; nothing is sealed to them.
    var pastDevices: [String: [ChatDeviceInfo]]?
    var holders: [String: String]?
    var writing: [ChatWritingWire]?
    var me: String?
    enum CodingKeys: String, CodingKey { case id, name, epoch, ai, members, messages, seals, devices, holders, writing, me; case isLocked = "private"; case pastDevices = "past_devices" }

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
            let said = (w.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty, said == lastReply { continue }
            // with no authenticated words, only the stage mark (what it is doing) is shown, until the finished message arrives
            let text = said.isEmpty ? (w.stage ?? "").trimmingCharacters(in: .whitespacesAndNewlines) : said
            out.append(ChatLine(id: "writing-\(w.name)", side: .theirs, speaker: showSpeakers ? shown(w.name) : nil, text: text, at: nil, streaming: true, unreadable: false))
        }
        return out
    }
}

// MARK: the list

enum ChatListing {
    /// What a chat is called: its own name (the PC names a chat after a few messages, or she renames it); else, in a chat with other people, who
    /// they are (a name they set for themselves in the chat, else their account's); else, in a chat with only an AI, its first words where they
    /// are known on this phone, else the day and time it was last used. Never the AI's own name, which every such chat shares ("Fingus"
    /// on every row, Aryn 2026-10-23); "New chat" when there is nothing else to go on.
    static func title(_ room: ChatRoomRow, me: String, firstWords: String? = nil, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if let name = room.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        let others = (room.members ?? []).filter { $0.kind == "person" && $0.name != me }.map { shownName($0) }
        if !others.isEmpty { return others.joined(separator: ", ") }
        let members = room.members ?? []
        if !members.isEmpty && !members.contains(where: { $0.kind == "model" }) { return "Just you" }
        if let words = firstWords?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty { return words }
        if let touched = room.touched, touched > 0 { return dateWords(Date(timeIntervalSince1970: touched), now: now, calendar: calendar, locale: locale) }
        return ChatWords.newChat
    }

    /// The first few words of what was said, to stand for a chat that has no name yet: at most `ChatListing.firstWordsMost` words and
    /// `firstWordsLength` characters, on one line. Picked, not grounded: a row has room for about this much at the list's type size.
    static let firstWordsMost = 6
    static let firstWordsLength = 32

    static func firstWords(of text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(firstWordsMost).joined(separator: " ")
        if words.isEmpty { return nil }
        if words.count <= firstWordsLength { return words }
        let cut = String(words.prefix(firstWordsLength)).trimmingCharacters(in: .whitespaces)
        return cut + "\u{2026}"
    }

    /// "Today, 9:41 pm", "Yesterday, 3:05 pm", or "Oct 22, 3:05 pm", in the person's own locale and clock.
    static func dateWords(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let clock = DateFormatter()
        clock.locale = locale; clock.calendar = calendar; clock.timeZone = calendar.timeZone
        clock.setLocalizedDateFormatFromTemplate("jmm")
        let time = clock.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday, \(time)" }
        let day = DateFormatter()
        day.locale = locale; day.calendar = calendar; day.timeZone = calendar.timeZone
        day.setLocalizedDateFormatFromTemplate("MMMd")
        return "\(day.string(from: date)), \(time)"
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

extension ChatModelPick {
    /// The models a chat may be switched to: the ones Aero offers (`rooms/people.json`); a Locked chat only the ones that run on the PC (the
    /// page's own rule for a private chat, `localModels`). The model it has now is always in the list, first when Aero no longer offers it.
    static func choices(from models: [String], privacy: ChatPrivacy, current: String?) -> [String] {
        var list = privacy == .locked ? models.filter(runsOnThePC) : models
        if let current, !current.isEmpty, !list.contains(current) { list.insert(current, at: 0) }
        return list
    }

    /// A model as the screen says it: "auto" is Automatic (Aero picks), anything else is its own name.
    static func shown(_ model: String) -> String {
        if model == "auto" { return "Automatic" }
        if model.hasPrefix("auto:") { return "Automatic: " + model.dropFirst(5) }
        return model
    }

    /// One line under a choice, from the page's own words (messages.js, "Who sees this"): where it runs, or what it is given.
    static func note(_ model: String) -> String {
        if runsOnThePC(model) { return "Runs on your PC" }
        if model.lowercased().hasPrefix("claude") { return "Gets this chat's messages, through Anthropic" }
        return "Gets this chat's messages"
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

// MARK: this phone as a device

/// What Aero answers when this phone says it is a device: whether a device she already uses has approved it, and the fruit name Aero gave it.
/// An older Aero answers only {ok}: it had no approval, so a missing `trusted` is read as trusted.
struct ChatRegistration: Equatable {
    var trusted: Bool
    var name: String?

    static func read(_ data: Data) -> ChatRegistration {
        struct Said: Decodable { var trusted: Bool?; var name: String? }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        return ChatRegistration(trusted: said?.trusted ?? true, name: said?.name)
    }
}

/// One of the person's devices for chats, as `devices/mine.json` lists it (public information only).
struct DeviceRow: Codable, Equatable, Identifiable {
    var device: String
    var name: String?
    var kind: String?
    var added: Double?
    var trusted: Bool
    var approvedBy: String?
    var ecdh: String
    var sign: String
    var id: String { device }
    enum CodingKeys: String, CodingKey { case device, name, kind, added, trusted, ecdh, sign; case approvedBy = "approved_by" }

    var shownName: String { (name ?? "").isEmpty ? "A device" : name! }
}

/// GET devices/mine.json: the server's clock (`now`, seconds) beside the list, because a signature is good only for a few minutes of the server's time.
struct DevicesAnswer: Codable, Equatable {
    var now: Double
    var devices: [DeviceRow]
}
