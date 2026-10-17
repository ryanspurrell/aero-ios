import Foundation
import CryptoKit

/// Something in the phone's own chat state stopped the work (no key yet, no model to talk to), as opposed to the server or the connection.
enum ChatSessionError: Error, Equatable {
    case noKey, noModel
}

// MARK: opening messages

/// Turning a stored (sealed) message into what the screen draws. Pure: the keys and devices are given.
enum ChatOpener {
    /// Whose device signed this message, as a key of the answer's `devices`: an AI's message by this PC's device (or Fingoid's; in a Locked
    /// chat once by a private device of one of its people), an add-on's by its holder's, a person's by their own.
    static func signer(of m: ChatWireMessage, locked: Bool, devices: [String: [ChatDeviceInfo]], holders: [String: String]) -> String {
        switch m.kind {
        case "model":
            if locked, let person = devices.keys.sorted().first(where: { name in
                !name.hasPrefix("@") && (devices[name] ?? []).contains { $0.device == m.device && ($0.isPrivate ?? false) }
            }) { return person }
            if (devices["@fingoid"] ?? []).contains(where: { $0.device == m.device }) { return "@fingoid" }
            return "@pc"
        case "addon":
            return holders[m.sender] ?? m.sender
        default:
            return m.sender
        }
    }

    static let beforeYouJoined = "Sent before you joined"
    static let notVerified = "This message couldn\u{2019}t be verified"
    static let notOpened = "This message couldn\u{2019}t be opened"

    static func entry(_ m: ChatWireMessage, room: String, keys: [String: SymmetricKey], devices: [String: [ChatDeviceInfo]], holders: [String: String], locked: Bool) -> ChatEntry {
        func plain(_ why: String?, text: String? = nil) -> ChatEntry {
            ChatEntry(seq: m.seq, kind: m.kind, sender: m.sender, text: text, note: m.kind == "note" ? m.note : nil, at: m.at, unreadable: why)
        }
        if m.kind == "note" { return plain(nil) }
        guard let epoch = m.epoch, let iv = m.iv, let ct = m.ct, let sig = m.sig, let device = m.device else { return plain(notOpened) }
        guard let key = keys["\(room)|\(epoch)"] else { return plain(beforeYouJoined) }
        let owner = signer(of: m, locked: locked, devices: devices, holders: holders)
        let signPublic = (devices[owner] ?? []).first(where: { $0.device == device })?.sign ?? ""
        do {
            let body = try ChatCrypto.open(room: room, epoch: epoch, sender: m.senderID ?? m.sender, device: device, iv: iv, ct: ct, sig: sig, key: key, signPublic: signPublic)
            // a reaction is an emoji under a message in the page, not a line of its own
            if body["re"] != nil { return plain(nil) }
            return plain(nil, text: body["t"] as? String)
        } catch ChatCryptoError.notVerified {
            return plain(notVerified)
        } catch {
            return plain(signPublic.isEmpty ? notVerified : notOpened)
        }
    }
}

// MARK: the session: who this is, this phone as a device, the keys opened

@MainActor
final class ChatSession {
    let api: ChatAPI
    private let keyStore: ChatKeyStore
    private(set) var me = ""
    private(set) var person = ""
    private var device: ChatDevice?
    private var registered = false
    /// Room keys opened on this phone, by "<room>|<epoch>". Kept in memory only; the sealed keys stay on the server.
    private(set) var keys: [String: SymmetricKey] = [:]

    init(api: ChatAPI = ChatAPI(), keyStore: ChatKeyStore = KeychainChatKeyStore()) {
        self.api = api
        self.keyStore = keyStore
    }

    /// The chats, and who this is (the keys are bound to the person id).
    func loadRooms() async throws -> ChatRoomsAnswer {
        let got = try await api.rooms()
        me = got.me
        person = got.person
        return got
    }

    /// This phone as a device of this person: made on first use, kept in the Keychain, and told to Aero once per launch (registering the same
    /// keys again changes nothing; Aero then has the PC share the keys of the chats it holds with this phone).
    func ensureDevice() async throws -> ChatDevice {
        if person.isEmpty { _ = try await loadRooms() }
        let d = device ?? ChatDeviceKeeper.device(for: person, in: keyStore)
        device = d
        if !registered {
            try await api.register(device: d, label: "iPhone")
            registered = true
        }
        return d
    }

    func key(room: String, epoch: Int) -> SymmetricKey? { keys["\(room)|\(epoch)"] }

    func hasAnyKey(room: String) -> Bool { keys.keys.contains { $0.hasPrefix(room + "|") } }

    func keep(_ key: SymmetricKey, room: String, epoch: Int) { keys["\(room)|\(epoch)"] = key }

    /// Open the keys sealed to this phone in a room answer.
    func openKeys(_ answer: ChatRoomAnswer, device d: ChatDevice) {
        for seal in answer.seals where keys["\(answer.id)|\(seal.epoch)"] == nil {
            guard let sealer = (answer.devices[seal.byPerson] ?? []).first(where: { $0.device == seal.byDevice }) else { continue }
            // sealed for someone else's key, or not ours: left closed
            if let key = try? ChatCrypto.unseal(room: answer.id, seal: seal, sealerEcdh: sealer.ecdh, device: d) { keep(key, room: answer.id, epoch: seal.epoch) }
        }
    }

    /// A Locked chat's keys are not kept once Locked closes.
    func forget(room: String) {
        for k in keys.keys where k.hasPrefix(room + "|") { keys[k] = nil }
    }

    /// Whether Locked is open (Face ID, held by Aero for this browser). An answer that cannot be had is a closed one.
    func lockedIsOpen() async -> Bool {
        (try? await api.lockedIsOpen()) ?? false
    }
}

// MARK: the list of chats

@MainActor
final class ChatListModel: ObservableObject {
    @Published private(set) var rooms: [ChatRoomRow] = []
    @Published private(set) var lockedOpen = false
    @Published private(set) var loaded = false
    @Published private(set) var stopped: ChatStopped?

    let session: ChatSession

    init(session: ChatSession) {
        self.session = session
    }

    var me: String { session.me }

    /// The rows to draw. Locked chats are in them only while Locked is open.
    var shown: [ChatRoomRow] { ChatListing.order(rooms, lockedOpen: lockedOpen) }

    func load() async {
        stopped = nil
        lockedOpen = await session.lockedIsOpen()
        do {
            rooms = try await session.loadRooms().rooms
            loaded = true
        } catch {
            stopped = ChatStopWords.make(doing: ChatStopWords.loadingList, error: error)
            if let f = error as? ChatAPI.Failure, f == .locked { lockedOpen = false }
        }
    }

    /// Locked closes (the app went to the background): its rows go at once, before anything is asked.
    func closeLocked() {
        lockedOpen = false
    }
}

// MARK: one chat

@MainActor
final class ChatRoomModel: ObservableObject {
    enum Phase: Equatable { case loading, locked, waitingForKeys, ready }

    @Published private(set) var lines: [ChatLine] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var stopped: ChatStopped?
    @Published private(set) var title: String
    @Published private(set) var replying = false
    @Published private(set) var sending = false
    @Published var draft = ""

    let session: ChatSession
    let privacy: ChatPrivacy
    private(set) var roomID: String?

    private var epoch = 0
    private var members: [ChatMember] = []
    private var wire: [Int: ChatWireMessage] = [:]
    private var devices: [String: [ChatDeviceInfo]] = [:]
    private var holders: [String: String] = [:]
    private var writing: [ChatWriting] = []
    private var lastSeq = 0
    private var following: Task<Void, Never>?
    private var waiting: Task<Void, Never>?

    /// An existing chat (its privacy is the chat's own), or, with no row, a new one that is made by its first message with the privacy chosen.
    init(session: ChatSession, room: ChatRoomRow?, privacy: ChatPrivacy) {
        self.session = session
        if let room {
            self.roomID = room.id
            self.privacy = room.locked ? .locked : .open
            self.title = ChatListing.title(room, me: session.me)
        } else {
            self.privacy = privacy
            self.title = ChatWords.newChat
        }
    }

    var isNew: Bool { roomID == nil }

    /// Show who said what: speaker names only where more than you and one reply are in the chat.
    private var showSpeakers: Bool { members.filter { $0.kind == "person" }.count > 1 || members.filter { $0.kind != "person" }.count > 1 }

    private func shown(_ name: String) -> String {
        if let m = members.first(where: { $0.name == name }) { return ChatListing.shownName(m) }
        return ChatListing.shownName(ChatMember(kind: "", name: name, nick: nil, model: nil))
    }

    // MARK: opening

    func load() async {
        stopped = nil
        guard let id = roomID else { phase = .ready; return }
        if privacy == .locked, !(await session.lockedIsOpen()) {
            shut()
            return
        }
        do {
            try await fetch(id)
        } catch {
            fail(ChatStopWords.opening, error)
        }
    }

    /// One read of the chat after what is already here; merges the new messages, opens new keys and redraws.
    private func fetch(_ id: String) async throws {
        let device = try await session.ensureDevice()
        let answer = try await session.api.room(id, device: device.id, after: lastSeq)
        epoch = answer.epoch
        members = answer.members
        for (name, list) in answer.devices { devices[name] = list }
        holders = answer.holders ?? holders
        writing = answer.writing ?? []
        for m in answer.messages { wire[m.seq] = m; lastSeq = max(lastSeq, m.seq) }
        session.openKeys(answer, device: device)
        if let name = answer.name, !name.isEmpty { title = name }
        redraw(id, locked: answer.locked || privacy == .locked)
        if lastSeq > 0 { await session.api.read(id, upTo: lastSeq) }
    }

    private func redraw(_ id: String, locked: Bool) {
        let ordered = wire.values.sorted { $0.seq < $1.seq }
        // Messages that need a key and no key of this chat has been opened here: the PC has not shared it yet.
        let needsKey = ordered.contains { $0.kind != "note" }
        if needsKey && !session.hasAnyKey(room: id) {
            lines = []
            phase = .waitingForKeys
            waitForKeys(id)
            return
        }
        let entries = ordered.map { ChatOpener.entry($0, room: id, keys: session.keys, devices: devices, holders: holders, locked: locked) }
        lines = ChatTranscript.lines(entries: entries, me: session.me, writing: writing, showSpeakers: showSpeakers, shown: shown(_:))
        phase = .ready
    }

    /// A chat this phone has no key to yet is asked for again every few seconds for a while: registering the phone asks the PC to share the
    /// keys it holds, and they arrive shortly after. The pause and the count are picked, not grounded.
    private func waitForKeys(_ id: String) {
        guard waiting == nil else { return }
        waiting = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .waitingForKeys else { break }
                try? await self.fetch(id)
            }
            self?.waiting = nil
        }
    }

    // MARK: Locked

    /// Locked closes (the app went to the background, or Aero said Locked): nothing of the chat stays on the screen or in memory.
    func shut() {
        guard privacy == .locked else { return }
        following?.cancel()
        waiting?.cancel()
        waiting = nil
        lines = []
        wire = [:]
        lastSeq = 0
        writing = []
        draft = ""
        if let id = roomID { session.forget(room: id) }
        phase = .locked
        replying = false
    }

    func leave() {
        following?.cancel()
        waiting?.cancel()
        waiting = nil
        if privacy == .locked { shut() }
    }

    // MARK: sending

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        stopped = nil
        defer { sending = false }
        if privacy == .locked, !(await session.lockedIsOpen()) {
            // the words stay in the box; nothing of the chat is shown
            shut()
            draft = text
            stopped = ChatStopWords.make(doing: ChatStopWords.sending, error: ChatAPI.Failure.locked)
            return
        }
        do {
            let device = try await session.ensureDevice()
            if roomID == nil { try await start(device: device) }
            guard let id = roomID else { return }
            var seq = 0
            for attempt in 0..<2 {
                guard let key = session.key(room: id, epoch: epoch) else { throw ChatSessionError.noKey }
                let sealed = try ChatCrypto.encrypt(room: id, epoch: epoch, key: key, text: text, device: device)
                do {
                    seq = try await session.api.send(id, .init(device: device.id, epoch: epoch, mentions: [], iv: sealed.iv, ct: sealed.ct, sig: sealed.sig))
                    break
                } catch ChatAPI.Failure.server(let words) where attempt == 0 && words.contains("key has changed") {
                    // the chat's key moved on while this was typed: read it again and seal to the new one
                    try await fetch(id)
                }
            }
            draft = ""
            try await fetch(id)
            follow(after: seq, id: id)
        } catch {
            // the words stay in the box
            fail(roomID == nil ? ChatStopWords.starting : ChatStopWords.sending, error)
        }
    }

    /// A new chat is made by its first message, with the privacy chosen before anything was said (the page does the same: mainRoom).
    private func start(device: ChatDevice) async throws {
        let models = try await session.api.models()
        guard let model = ChatModelPick.pick(from: models, privacy: privacy) else { throw ChatSessionError.noModel }
        let me = session.me
        let people = [me, "@pc", "@fingoid"]
        let found = try await session.api.devices(of: people)
        var targets: [ChatDeviceKeys] = []
        for name in people {
            for d in found[name] ?? [] { targets.append(ChatDeviceKeys(device: d.device, ecdh: d.ecdh, personID: d.personID ?? name)) }
        }
        let id = ChatCrypto.roomID()
        let key = ChatCrypto.freshKey()
        let seals = try ChatCrypto.seal(room: id, epoch: 0, key: key, to: targets, person: me, from: device)
        try await session.api.newRoom(.init(device: device.id, room: id, name: "", members: [.init(kind: "model", name: "fingus", model: model)],
                                            seals: seals, private: privacy == .locked))
        session.keep(key, room: id, epoch: 0)
        roomID = id
        epoch = 0
    }

    // MARK: following a reply

    /// Ask again and again while a reply is being written, drawing it as far as it has got (the server's `writing`), and until the finished
    /// reply is among the messages. Leaving the chat stops asking; the reply carries on at the PC.
    private func follow(after sent: Int, id: String) {
        following?.cancel()
        let started = Date()
        replying = true
        following = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await self.fetch(id)
                let sawReply = self.wire.values.contains { $0.kind == "model" && $0.seq > sent }
                let busy = self.writing.isEmpty ? ((try? await self.session.api.busy(id)) ?? false) : true
                if !ChatPollPlan.shouldContinue(writing: !self.writing.isEmpty, busy: busy, sawReply: sawReply, secondsSinceSend: Date().timeIntervalSince(started)) { break }
                try? await Task.sleep(nanoseconds: UInt64(ChatPollPlan.interval * 1_000_000_000))
            }
            self?.replying = false
        }
    }

    func stopReply() async {
        guard let id = roomID else { return }
        do { try await session.api.stop(id) } catch { fail(ChatStopWords.stoppingReply, error) }
    }

    // MARK: the one shape

    private func fail(_ doing: String, _ error: Error) {
        stopped = ChatStopWords.make(doing: doing, error: error)
        if let f = error as? ChatAPI.Failure, f == .locked, privacy == .locked { shut() }
    }

    /// The key under a stopped note.
    func retry() async {
        guard let s = stopped else { return }
        if s.action == .retry {
            if draft.isEmpty { await load() } else { await send() }
        }
    }
}
