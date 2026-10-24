import Foundation
import CryptoKit

/// Something in the phone's own chat state stopped the work (no key yet, no model to talk to), as opposed to the server or the connection.
enum ChatSessionError: Error, Equatable {
    case noKey, noModel
}

/// The account or the lock changed while something was being asked; its answer is dropped, not used.
struct ChatStale: Error {}

// MARK: opening messages

/// Turning a stored (sealed) message into what the screen draws. Pure: the keys and devices are given.
enum ChatOpener {
    /// Whose device signed this message, as a key of the answer's `devices`: an AI's message by this PC's device (or Fingoid's; in a Locked
    /// chat once by a private device of one of its people), an add-on's by its holder's, a person's by their own.
    static func signer(of m: ChatWireMessage, locked: Bool, devices: [String: [ChatDeviceInfo]], past: [String: [ChatDeviceInfo]] = [:], holders: [String: String]) -> String {
        switch m.kind {
        case "model":
            // (a private device removed since still counts: its keys come in `past`, with the same mark)
            if locked, let person = Set(devices.keys).union(past.keys).sorted().first(where: { name in
                !name.hasPrefix("@") && ((devices[name] ?? []) + (past[name] ?? [])).contains { $0.device == m.device && ($0.isPrivate ?? false) }
            }) { return person }
            if ((devices["@fingoid"] ?? []) + (past["@fingoid"] ?? [])).contains(where: { $0.device == m.device }) { return "@fingoid" }
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

    static func entry(_ m: ChatWireMessage, room: String, keys: [String: SymmetricKey], devices: [String: [ChatDeviceInfo]], past: [String: [ChatDeviceInfo]] = [:], holders: [String: String], locked: Bool) -> ChatEntry {
        func plain(_ why: String?, text: String? = nil) -> ChatEntry {
            ChatEntry(seq: m.seq, kind: m.kind, sender: m.sender, text: text, note: m.kind == "note" ? m.note : nil, at: m.at, unreadable: why)
        }
        if m.kind == "note" { return plain(nil) }
        guard let epoch = m.epoch, let iv = m.iv, let ct = m.ct, let sig = m.sig, let device = m.device else { return plain(notOpened) }
        guard let key = keys["\(room)|\(epoch)"] else { return plain(beforeYouJoined) }
        let owner = signer(of: m, locked: locked, devices: devices, past: past, holders: holders)
        // the devices there are now, then those removed since: a message a removed device signed still checks
        let signPublic = ((devices[owner] ?? []) + (past[owner] ?? [])).first(where: { $0.device == device })?.sign ?? ""
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

// MARK: the safety code, remembered

/// One person's (or the PC's) safety code in a chat, and where it stands: never compared, compared and the same, or different from the one that
/// was compared.
struct ChatSafetyRow: Equatable, Identifiable {
    enum Status: Equatable { case unchecked, checked, changed }
    var name: String
    var code: String
    var status: Status
    var id: String { name }
    var changed: Bool { status == .changed }
}

/// The safety codes the person has compared, kept on the phone (a code is a hash of public keys, not a secret). A code the server gave is
/// "not compared yet" until the person says it matches; only that yes is remembered, so there is no silent first baseline, and a different code
/// after it is shown as changed until the person compares again.
final class ChatSafetyLedger {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private func key(_ account: String, _ name: String) -> String { "AeroChatSafety|\(account)|\(name)" }

    func rows(account: String, devices: [String: [ChatDeviceInfo]]) -> [ChatSafetyRow] {
        devices.keys.sorted().compactMap { name in
            let code = ChatCrypto.safetyCode((devices[name] ?? []).map { (ecdh: $0.ecdh, sign: $0.sign) })
            guard !code.isEmpty else { return nil }
            guard let accepted = defaults.string(forKey: key(account, name)) else { return ChatSafetyRow(name: name, code: code, status: .unchecked) }
            return ChatSafetyRow(name: name, code: code, status: accepted == code ? .checked : .changed)
        }
    }

    func accept(account: String, name: String, code: String) {
        defaults.set(code, forKey: key(account, name))
    }

    /// Everything remembered for an account (sign-out).
    func forget(account: String) {
        for k in defaults.dictionaryRepresentation().keys where k.hasPrefix("AeroChatSafety|\(account)|") { defaults.removeObject(forKey: k) }
    }
}

/// One piece of work at a time, shared: a call made while it runs waits for the same result instead of starting the work again.
@MainActor
final class ChatSingleFlight<Value> {
    private var running: Task<Value, Error>?
    private var serial = 0

    func run(_ work: @escaping @MainActor () async throws -> Value) async throws -> Value {
        if let running { return try await running.value }
        serial += 1
        let mine = serial
        let task = Task { () -> Value in
            defer { if self.serial == mine { self.running = nil } }
            return try await work()
        }
        running = task
        return try await task.value
    }

    /// What is running is no longer the one to join (an account changed): the next call starts its own.
    func forget() {
        running = nil
        serial += 1
    }
}

// MARK: the session: who this is, this phone as a device, the keys opened

/// What the person is asked when the old keys cannot open some chats: how many chats would stay closed, Aero's acknowledgement of exactly those,
/// and the two devices (kept so that the answer can finish the move).
struct ChatRenewalChoice {
    let rooms: Int
    let ack: String
    let old: ChatDevice
    let fresh: ChatDevice
}

@MainActor
final class ChatSession {
    let api: ChatAPI
    private let keyStore: ChatKeyStore
    let safety: ChatSafetyLedger
    private(set) var me = ""
    private(set) var person = ""
    private var device: ChatDevice?
    private var registered = false
    /// What Aero said when this phone last said it is a device: its fruit name, and whether a device she already uses has approved it. A device
    /// that is waiting is sealed no chat keys, so its chats cannot open until it is approved.
    private(set) var registration: ChatRegistration?
    /// The id of this phone as a chat device, once it has been made.
    var deviceID: String? { device?.id }
    /// Set when this phone is waiting for approval: the words for it need its name.
    var waitingForApproval: ChatRegistration? { registration.flatMap { $0.trusted ? nil : $0 } }
    /// The first words of a chat opened on this phone, to stand for it in the list while it has no name. In memory only, never for a Locked chat,
    /// and gone with the account.
    private(set) var firstWords: [String: String] = [:]
    /// Room keys opened on this phone, by "<room>|<epoch>". Kept in memory only; the sealed keys stay on the server.
    private(set) var keys: [String: SymmetricKey] = [:]
    /// Changes whenever the account changes or signs out; anything asked before the change is dropped when it answers.
    private(set) var generation = 0
    /// Told when everything held for the old account has been cleared, so the screens clear what they drew.
    var onReset: (() -> Void)?
    /// This phone's chat keys were replaced because an earlier build had kept them in a way that is no longer used; the person is told.
    private(set) var renewedKeys = false
    /// The move to the Secure Enclave stopped because the new device could not open everything the old one can; the old one stays in use.
    private(set) var renewalProblem: String?
    /// The old keys cannot open some chats, so they cannot be brought across: what the person is asked, until they answer. Nothing is changed
    /// before they say (`acceptRenewalLoss` / `declineRenewalLoss`).
    private(set) var renewalChoice: ChatRenewalChoice?
    private var flight: Task<(ChatRoomsAnswer, Int), Error>?
    private var flightSerial = 0
    /// The one `ensureDevice` that is running; a second call joins it (two screens asking on a first launch must not each make and
    /// register a device).
    private let deviceFlight = ChatSingleFlight<ChatDevice>()

    init(api: ChatAPI = ChatAPI(), keyStore: ChatKeyStore = KeychainChatKeyStore(), safety: ChatSafetyLedger = ChatSafetyLedger()) {
        self.api = api
        self.keyStore = keyStore
        self.safety = safety
    }

    /// The account changed or signed out: the device, its registration, every room key and the cookies are dropped, and the screens told.
    func reset() {
        generation += 1
        flightSerial += 1
        flight = nil
        deviceFlight.forget()
        device = nil
        registered = false
        registration = nil
        firstWords = [:]
        keys = [:]
        renewalProblem = nil
        renewalChoice = nil
        me = ""
        person = ""
        api.forgetCookies()
        onReset?()
    }

    /// A refusal that means this browser is not signed in (any other failure leaves the account as it is).
    func note(_ error: Error) {
        if let f = error as? ChatAPI.Failure, f == .notSignedIn { reset() }
    }

    /// The chats, and who this is (the keys are bound to the person id), with the generation this answer belongs to. Asked once at a time: a
    /// second call joins the first. A different person than before clears everything held for the last and the answer is the new person's own;
    /// an answer that was overtaken by a reset (a sign-out, another account) is dropped.
    func loadRooms() async throws -> (answer: ChatRoomsAnswer, generation: Int) {
        if let f = flight { return try await f.value }
        let g = generation
        flightSerial += 1
        let serial = flightSerial
        let task = Task { () -> (ChatRoomsAnswer, Int) in
            defer { if self.flightSerial == serial { self.flight = nil } }
            let got = try await self.api.rooms()
            guard g == self.generation else { throw ChatStale() }
            if !self.person.isEmpty && got.person != self.person { self.reset() }
            self.me = got.me
            self.person = got.person
            return (got, self.generation)
        }
        flight = task
        return try await task.value
    }

    /// This phone as a device of this person: made on first use, kept in the Keychain (Secure Enclave keys where there is one), and told to
    /// Aero once per launch (registering the same keys again changes nothing; Aero then has the PC share the keys of the chats it holds).
    func ensureDevice() async throws -> ChatDevice {
        try await deviceFlight.run { try await self.ensureDeviceOnce() }
    }

    private func ensureDeviceOnce() async throws -> ChatDevice {
        if person.isEmpty { _ = try await loadRooms() }
        let g = generation
        let firstThisLaunch = device == nil
        var current: ChatDevice
        if let have = device { current = have } else { current = try ChatDeviceKeeper.device(for: person, in: keyStore) }
        if !registered {
            var said: ChatRegistration
            do { said = try await api.register(device: current, label: ChatWords.deviceLabel) }
            catch ChatAPI.Failure.deviceRemoved {
                // removed from the person's list but still has its keys: it starts again with new ones, as a new device
                current = try ChatDeviceKeeper.startAgain(for: person, in: keyStore)
                said = try await api.register(device: current, label: ChatWords.deviceLabel)
                renewedKeys = true
            }
            guard g == generation else { throw ChatStale() }
            registration = said
            registered = true
        }
        if firstThisLaunch, let moved = await renewIfSafe(current) { current = moved }
        device = current
        return current
    }

    /// While this phone waits for approval, asks Aero whether it has been given yet (a device she already uses approves it; Aero then has the PC
    /// share the keys it holds). Does nothing once it is approved, and nothing when Aero cannot be asked: it stays waiting.
    func refreshTrust() async {
        guard let id = device?.id, registration?.trusted == false else { return }
        let g = generation
        guard let mine = try? await api.devicesMine(), g == generation, let row = mine.devices.first(where: { $0.device == id }) else { return }
        registration = ChatRegistration(trusted: row.trusted, name: row.name ?? registration?.name)
    }

    /// Remember the first words of a chat for its row. Not for a Locked chat.
    func noteFirstWords(room: String, from text: String, locked: Bool) {
        guard !locked, firstWords[room] == nil, let words = ChatListing.firstWords(of: text) else { return }
        firstWords[room] = words
    }

    /// A device made by an earlier build with raw keys, on a phone with a Secure Enclave, is moved to the Secure Enclave, but only
    /// when nothing is lost by it. What the old device alone can open can only be opened with its keys, so they are discarded last, and
    /// only after Aero has taken the old device out of the list, which it does only if the new device has proved it opened its seal of every
    /// key the old one holds (Aero's check, made in one step with the removal: nothing changed since can slip through). In this order:
    ///  1. the new device is made once and kept, private keys too, apart from the person's own (`ChatNextDevice`), because what is to be
    ///     sealed to it can only be opened with them; it is registered (refused when the eight places are taken: the old one stays);
    ///  2. Aero is asked to take the old device out for it: refused until the PC or another device has sealed everything to the new one;
    ///     then the old device stays in use and this is asked again at the next launch (the new entry waits in the list meanwhile);
    ///  3. only then are the new keys kept as the person's own (the old ones go), and the next device cleared. If that save fails the new
    ///     device is used for this launch, and the next launch starts again with it, because Aero then refuses the old (removed) one.
    private func renewIfSafe(_ old: ChatDevice) async -> ChatDevice? {
        guard old.canMoveToEnclave else { return nil }
        let g = generation
        let who = person
        let fresh: ChatDevice
        if let next = ChatNextDevice.load(person: who, in: keyStore) { fresh = next }
        else {
            guard let made = try? ChatDevice.make(person: who), !made.isSoftware, (try? ChatNextDevice.keep(made, in: keyStore)) != nil else { return nil }
            fresh = made
        }
        do { try await api.register(device: fresh, label: ChatWords.deviceLabel) }
        catch ChatAPI.Failure.deviceRemoved { ChatNextDevice.clear(person: who, in: keyStore); return nil }   // taken out by the person: made again next time
        catch { return nil }
        guard g == generation else { return nil }
        // Aero can only see that a seal exists, not whether it opens, and cannot open one itself: so this phone opens every one (every room and
        // epoch, hidden or not) with the old keys and with the new, compares the two keys, and signs for each device what it opened; Aero takes
        // only what the two say alike. Anything else stops here, with the old device kept.
        let outcome = await replacementOpensEverything(old: old, fresh: fresh)
        guard g == generation else { return nil }
        switch outcome {
        case .opensAll:
            break
        case .waits:
            renewalProblem = ChatWords.renewalStopped
            return nil
        case .oldCannotOpen:
            // The old keys cannot open some seal, so nothing can show the new ones open the same: waiting does not help. Aero says what would stay
            // closed; the person is told in plain words and chooses. Nothing is removed unless they do.
            do { try await api.removeDevice(old.id, replacedBy: fresh.id) }
            catch ChatAPI.Failure.notCovered(let rooms, let ack) where !ack.isEmpty {
                renewalChoice = ChatRenewalChoice(rooms: rooms, ack: ack, old: old, fresh: fresh)
                return nil
            } catch { renewalProblem = ChatWords.renewalStopped; return nil }
            renewedKeys = true
            do { try ChatDeviceKeeper.replace(old, with: fresh, in: keyStore) } catch { /* used for this launch; see above */ }
            return fresh
        }
        do { try await api.removeDevice(old.id, replacedBy: fresh.id) } catch { return nil }
        renewedKeys = true
        do { try ChatDeviceKeeper.replace(old, with: fresh, in: keyStore) } catch { /* used for this launch; see above */ }
        return fresh
    }

    /// The person said to move on and leave the chats the old keys cannot open closed: Aero is sent its own acknowledgement of exactly those,
    /// and removes the old device only if what would stay closed is still what was said (otherwise it says it again, as it is now, and nothing
    /// is removed). Then the new keys are kept as the person's own.
    func acceptRenewalLoss() async {
        guard let choice = renewalChoice else { return }
        let g = generation
        do { try await api.removeDevice(choice.old.id, replacedBy: choice.fresh.id, ack: choice.ack) }
        catch ChatAPI.Failure.notCovered(let rooms, let ack) where !ack.isEmpty {
            if g == generation { renewalChoice = ChatRenewalChoice(rooms: rooms, ack: ack, old: choice.old, fresh: choice.fresh) }
            return
        } catch { return }      // not reached Aero: still asked, nothing changed
        guard g == generation else { return }
        renewalChoice = nil
        renewedKeys = true
        do { try ChatDeviceKeeper.replace(choice.old, with: choice.fresh, in: keyStore) } catch { /* used for this launch; the next starts again */ }
        device = choice.fresh
    }

    /// The person chose to keep things as they are: nothing changes, and it is asked again at the next launch.
    func declineRenewalLoss() {
        renewalChoice = nil
        renewalProblem = ChatWords.renewalDeclined
    }

    private enum Replacement { case opensAll, waits, oldCannotOpen }

    /// Every key the old device holds, in every room and epoch, hidden rooms too: the full list comes from Aero's `devices/keys.json` (a
    /// device's own keys, no content, not held back by Locked), not from the chat list, which leaves out a Locked chat while Locked is shut.
    /// Each is opened here with the old keys and with the new and the two compared, and a signed proof from each device is sent to Aero, which
    /// removes the old device only once the two say the same for all of them. `.waits` when anything cannot be asked or sent, or the new
    /// keys do not open to the same key (the PC may yet seal it right); `.oldCannotOpen` when the old keys themselves cannot open some seal
    /// and everything else is proved (`ChatRenewalCheck.prove`).
    private func replacementOpensEverything(old: ChatDevice, fresh: ChatDevice) async -> Replacement {
        guard let theirs = try? await api.heldKeys(device: old.id), let mine = try? await api.heldKeys(device: fresh.id) else { return .waits }
        let result = ChatRenewalCheck.prove(theirs: theirs, mine: mine, old: old, fresh: fresh)
        do {
            try await api.prove(device: fresh.id, proofs: result.proofs)
            try await api.prove(device: old.id, proofs: result.oldProofs)
        } catch { return .waits }
        if result.unopened > 0 { return .waits }
        return result.oldCannotOpen > 0 ? .oldCannotOpen : .opensAll
    }

    func key(room: String, epoch: Int) -> SymmetricKey? { keys["\(room)|\(epoch)"] }

    func hasAnyKey(room: String) -> Bool { keys.keys.contains { $0.hasPrefix(room + "|") } }

    func keep(_ key: SymmetricKey, room: String, epoch: Int) { keys["\(room)|\(epoch)"] = key }

    /// Open the keys sealed to this phone in a room answer.
    func openKeys(_ answer: ChatRoomAnswer, device d: ChatDevice) {
        for seal in answer.seals where keys["\(answer.id)|\(seal.epoch)"] == nil {
            // a seal the old device made stays after it is removed: its public keys are given too (`pastDevices`), only for opening
            guard let sealer = ((answer.devices[seal.byPerson] ?? []) + (answer.pastDevices?[seal.byPerson] ?? [])).first(where: { $0.device == seal.byDevice }) else { continue }
            // sealed for someone else's key, not 32 bytes, or not ours: left closed
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
    /// Asked when the old keys cannot open some chats (see `ChatSession.renewalChoice`); read from the session after each load and answer.
    @Published private(set) var renewalChoice: ChatRenewalChoice?
    /// Set while this phone waits for a device she already uses to approve it (its fruit name is in it).
    @Published private(set) var waiting: ChatRegistration?

    let session: ChatSession

    init(session: ChatSession) {
        self.session = session
    }

    /// What a row is called: its name, who is in it, its first words if they are known here, or when it was last used.
    func title(_ row: ChatRoomRow) -> String {
        ChatListing.title(row, me: me, firstWords: session.firstWords[row.id])
    }

    var me: String { session.me }

    /// The rows to draw. Locked chats are in them only while Locked is open.
    var shown: [ChatRoomRow] { ChatListing.order(rooms, lockedOpen: lockedOpen) }

    /// Changes whenever Locked closes or a new load starts; an answer asked for under an older one is dropped when it arrives.
    private var loadToken = 0

    /// The notice that this phone's chat keys were renewed, until the person has seen it.
    var renewedNotice: String? { session.renewedKeys ? ChatWords.keysRenewed : session.renewalProblem }

    func load() async {
        if DemoMode.chatDemo { rooms = DemoMode.chatRows; loaded = true; return }
        stopped = nil
        loadToken += 1
        let token = loadToken
        let open = await session.lockedIsOpen()
        guard token == loadToken else { return }
        do {
            let got = try await session.loadRooms()
            // dropped if Locked closed, a newer load started, or the account was reset by something else while it was asked
            guard token == loadToken, got.generation == session.generation else { return }
            lockedOpen = open
            rooms = got.answer.rooms
            loaded = true
            // this phone is made a device of the person here, as the page does on opening Talk, so the list can say when it still waits
            // for approval; a failure shows when a chat is opened
            _ = try? await session.ensureDevice()
            await session.refreshTrust()
            guard token == loadToken, got.generation == session.generation else { return }
            waiting = session.waitingForApproval
            renewalChoice = session.renewalChoice
        } catch is ChatStale {
            return
        } catch {
            session.note(error)
            guard token == loadToken else { return }
            stopped = ChatStopWords.make(doing: ChatStopWords.loadingList, error: error)
            if let f = error as? ChatAPI.Failure, f == .locked { closeLocked() }
        }
    }

    /// The person's answer to `renewalChoice`: move on and leave those chats closed, or keep things as they are.
    func acceptRenewalLoss() async {
        await session.acceptRenewalLoss()
        renewalChoice = session.renewalChoice
    }

    func declineRenewalLoss() {
        session.declineRenewalLoss()
        renewalChoice = session.renewalChoice
    }

    /// Locked closes (the app went to the background, or Aero said Locked): its rows go at once, before anything is asked, and are not kept;
    /// a load that was already on its way is dropped when it answers.
    func closeLocked() {
        loadToken += 1
        lockedOpen = false
        rooms = rooms.filter { !$0.locked }
    }

    /// Everything drawn for the last account.
    func clear() {
        loadToken += 1
        waiting = nil
        rooms = []
        loaded = false
        stopped = nil
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
    @Published private(set) var safety: [ChatSafetyRow] = []
    @Published var draft = ""
    /// The model answering in this chat (the first AI member's), or for a chat not yet started the one it will start with; nil when none is known.
    @Published private(set) var modelName: String?
    /// The models it may be switched to, read when the chooser opens (and for a new chat when it opens).
    @Published private(set) var modelChoices: [String] = []
    @Published private(set) var changing = false
    /// Set while this phone waits for a device she already uses to approve it.
    @Published private(set) var waitingForApproval: ChatRegistration?

    let session: ChatSession
    let privacy: ChatPrivacy
    private(set) var roomID: String?

    private var epoch = 0
    private var members: [ChatMember] = []
    /// The name of the AI member whose model is switched (its name in the chat, not its model).
    private var modelMember: String { members.first(where: { $0.kind == "model" })?.name ?? "fingus" }
    private var wire: [Int: ChatWireMessage] = [:]
    private var devices: [String: [ChatDeviceInfo]] = [:]
    private var pastDevices: [String: [ChatDeviceInfo]] = [:]
    private var holders: [String: String] = [:]
    private var writing: [ChatWriting] = []
    private var lastSeq = 0
    private var following: Task<Void, Never>?
    private var waiting: Task<Void, Never>?
    /// Changes each time Locked closes; a result asked for before that is dropped when it arrives.
    private var lockGeneration = 0

    /// What a result must still match when it arrives: the lock has not closed and the account has not changed since it was asked for.
    private struct Token { var lock: Int; var account: Int }
    private func token() -> Token { Token(lock: lockGeneration, account: session.generation) }
    private func check(_ t: Token) throws {
        if t.lock != lockGeneration || t.account != session.generation { throw ChatStale() }
    }

    /// An existing chat (its privacy is the chat's own), or, with no row, a new one that is made by its first message with the privacy chosen.
    init(session: ChatSession, room: ChatRoomRow?, privacy: ChatPrivacy) {
        self.session = session
        if let room {
            self.roomID = room.id
            self.privacy = room.locked ? .locked : .open
            self.title = ChatListing.title(room, me: session.me, firstWords: session.firstWords[room.id])
            self.modelName = room.members?.first(where: { $0.kind == "model" })?.model
        } else {
            self.privacy = privacy
            self.title = ChatWords.newChat
        }
    }

    var isNew: Bool { roomID == nil }

    var keysChanged: Bool { safety.contains { $0.changed } }
    var allChecked: Bool { !safety.isEmpty && safety.allSatisfy { $0.status == .checked } }

    /// Show who said what: speaker names only where more than you and one reply are in the chat.
    private var showSpeakers: Bool { members.filter { $0.kind == "person" }.count > 1 || members.filter { $0.kind != "person" }.count > 1 }

    private func shown(_ name: String) -> String {
        if let m = members.first(where: { $0.name == name }) { return ChatListing.shownName(m) }
        return ChatListing.shownName(ChatMember(kind: "", name: name, nick: nil, model: nil))
    }

    // MARK: opening

    func load() async {
        if DemoMode.chatDemo { lines = DemoMode.chatLines; phase = .ready; modelChoices = DemoMode.chatModels; return }
        stopped = nil
        guard let id = roomID else {
            phase = .ready
            await prepareNew()
            return
        }
        let t = token()
        if privacy == .locked {
            let open = await session.lockedIsOpen()
            guard (try? check(t)) != nil else { return }
            if !open { shut(); return }
        }
        do {
            try await fetch(id, t)
        } catch is ChatStale {
            return
        } catch {
            fail(ChatStopWords.opening, error, t)
        }
    }

    /// One read of the chat after what is already here; merges the new messages, opens new keys and redraws. Anything that arrives after the lock
    /// closed or the account changed is dropped before it touches the keys or the screen.
    private func fetch(_ id: String, _ t: Token) async throws {
        let device = try await session.ensureDevice()
        try check(t)
        let answer = try await session.api.room(id, device: device.id, after: lastSeq)
        try check(t)
        epoch = answer.epoch
        members = answer.members
        for (name, list) in answer.devices { devices[name] = list }
        for (name, list) in answer.pastDevices ?? [:] { pastDevices[name] = list }
        holders = answer.holders ?? holders
        for m in answer.messages { wire[m.seq] = m; lastSeq = max(lastSeq, m.seq) }
        session.openKeys(answer, device: device)
        // the words so far of a reply come sealed (`live`); only what opens under the room key with the exact additional data is shown
        writing = (answer.writing ?? []).map { w in
            var said: String?
            if let live = w.live, let key = session.key(room: id, epoch: live.epoch) { said = try? ChatCrypto.openLive(room: id, live: live, key: key) }
            return ChatWriting(name: w.name, text: said, stage: w.stage)
        }
        if let name = answer.name, !name.isEmpty { title = name }
        if let current = answer.members.first(where: { $0.kind == "model" })?.model, !current.isEmpty { modelName = current }
        waitingForApproval = session.waitingForApproval
        safety = session.safety.rows(account: session.person, devices: devices)
        redraw(id, locked: answer.locked || privacy == .locked, t)
        if lastSeq > 0 { await session.api.read(id, upTo: lastSeq) }
    }

    private func redraw(_ id: String, locked: Bool, _ t: Token) {
        let ordered = wire.values.sorted { $0.seq < $1.seq }
        // Messages that need a key and no key of this chat has been opened here: the PC has not shared it yet.
        let needsKey = ordered.contains { $0.kind != "note" }
        if needsKey && !session.hasAnyKey(room: id) {
            lines = []
            phase = .waitingForKeys
            waitForKeys(id, t)
            return
        }
        let entries = ordered.map { ChatOpener.entry($0, room: id, keys: session.keys, devices: devices, past: pastDevices, holders: holders, locked: locked) }
        lines = ChatTranscript.lines(entries: entries, me: session.me, writing: writing, showSpeakers: showSpeakers, shown: shown(_:))
        // an unnamed chat is called by its first words where they were opened here (never a Locked chat's)
        if !locked, let first = lines.first(where: { $0.side == .mine && !$0.unreadable }) {
            session.noteFirstWords(room: id, from: first.text, locked: false)
            if let name = session.firstWords[id], title.isEmpty || title == ChatWords.newChat { title = name }
        }
        phase = .ready
    }

    /// A chat this phone has no key to yet is asked for again every few seconds for a while: registering the phone asks the PC to share the
    /// keys it holds, and they arrive shortly after. The pause and the count are picked, not grounded.
    private func waitForKeys(_ id: String, _ t: Token) {
        guard waiting == nil else { return }
        waiting = Task { [weak self] in
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, !Task.isCancelled, self.phase == .waitingForKeys, (try? self.check(t)) != nil else { break }
                await self.session.refreshTrust()
                try? await self.fetch(id, t)
            }
            self?.waiting = nil
        }
    }

    // MARK: Locked

    /// Locked closes (the app went to the background, or Aero said Locked): everything of the chat is cleared, the draft included and never
    /// restored, and anything still on its way is dropped when it arrives. (Swift cannot promise that copies of strings or data are zeroed;
    /// what is done is that nothing refers to them.)
    func shut() {
        guard privacy == .locked else { return }
        lockGeneration += 1
        following?.cancel(); following = nil
        waiting?.cancel(); waiting = nil
        lines = []
        wire = [:]
        devices = [:]
        holders = [:]
        members = []
        writing = []
        safety = []
        lastSeq = 0
        epoch = 0
        draft = ""
        stopped = nil
        title = ChatWords.lockedTitle
        modelName = nil
        modelChoices = []
        if let id = roomID { session.forget(room: id) }
        phase = .locked
        replying = false
        sending = false
    }

    func leave() {
        following?.cancel(); following = nil
        waiting?.cancel(); waiting = nil
        if privacy == .locked { shut() }
    }

    /// The account changed: everything of the chat is cleared whatever its privacy.
    func clearAll() {
        lockGeneration += 1
        following?.cancel(); following = nil
        waiting?.cancel(); waiting = nil
        lines = []; wire = [:]; devices = [:]; holders = [:]; members = []; writing = []; safety = []
        lastSeq = 0; epoch = 0; draft = ""; stopped = nil
        phase = .loading; replying = false; sending = false
    }

    /// The person says they have looked at someone's code and it is right.
    func accept(_ row: ChatSafetyRow) {
        session.safety.accept(account: session.person, name: row.name, code: row.code)
        safety = session.safety.rows(account: session.person, devices: devices)
    }

    // MARK: sending

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        stopped = nil
        let t = token()
        defer { if (try? check(t)) != nil { sending = false } }
        if privacy == .locked {
            let open = await session.lockedIsOpen()
            guard (try? check(t)) != nil else { return }
            if !open {
                // nothing of the chat is shown, and the words are not put back in the box
                shut()
                stopped = ChatStopWords.make(doing: ChatStopWords.sending, error: ChatAPI.Failure.locked)
                return
            }
        }
        do {
            let device = try await session.ensureDevice()
            try check(t)
            // a device that is waiting is sealed no keys: a chat started or answered here could not be opened here
            await session.refreshTrust()
            try check(t)
            if let waiting = session.waitingForApproval {
                waitingForApproval = waiting
                stopped = ChatStopped(doing: ChatStopWords.sending, step: ChatStep.devices, next: "", key: ChatWords.waitingCheck, action: .retry,
                                      words: ChatWords.waitingToSend(waiting.name), diagnosis: "other")
                return
            }
            if roomID == nil { try await start(device: device, t) }
            guard let id = roomID else { return }
            var seq = 0
            for attempt in 0..<2 {
                guard let key = session.key(room: id, epoch: epoch) else { throw ChatSessionError.noKey }
                let sealed = try ChatCrypto.encrypt(room: id, epoch: epoch, key: key, text: text, device: device)
                do {
                    seq = try await session.api.send(id, .init(device: device.id, epoch: epoch, mentions: [], iv: sealed.iv, ct: sealed.ct, sig: sealed.sig))
                    try check(t)
                    break
                } catch ChatAPI.Failure.server(let words) where attempt == 0 && words.contains("key has changed") {
                    // the chat's key moved on while this was typed: read it again and seal to the new one
                    try await fetch(id, t)
                }
            }
            draft = ""
            try await fetch(id, t)
            follow(after: seq, id: id, t)
        } catch is ChatStale {
            return
        } catch {
            // the words stay in the box (an Open chat; a Locked one that closed was cleared above)
            fail(roomID == nil ? ChatStopWords.starting : ChatStopWords.sending, error, t)
        }
    }

    /// A new chat is made by its first message, with the privacy chosen before anything was said (the page does the same: mainRoom).
    private func start(device: ChatDevice, _ t: Token) async throws {
        let models = try await session.api.models()
        try check(t)
        // the one chosen above the box, if Aero still offers it, else the first it offers (for a Locked chat, the first that runs on the PC)
        let allowed = ChatModelPick.choices(from: models, privacy: privacy, current: nil)
        let wanted = modelName.flatMap { allowed.contains($0) ? $0 : nil }
        guard let model = wanted ?? ChatModelPick.pick(from: models, privacy: privacy) else { throw ChatSessionError.noModel }
        let me = session.me
        let people = [me, "@pc", "@fingoid"]
        let found = try await session.api.devices(of: people)
        try check(t)
        var targets: [ChatDeviceKeys] = []
        for name in people {
            for d in found[name] ?? [] { targets.append(ChatDeviceKeys(device: d.device, ecdh: d.ecdh, personID: d.personID ?? name)) }
        }
        let id = ChatCrypto.roomID()
        let key = ChatCrypto.freshKey()
        let seals = try ChatCrypto.seal(room: id, epoch: 0, key: key, to: targets, person: me, from: device)
        try await session.api.newRoom(.init(device: device.id, room: id, name: "", members: [.init(kind: "model", name: "fingus", model: model)],
                                            seals: seals, private: privacy == .locked))
        try check(t)
        session.keep(key, room: id, epoch: 0)
        roomID = id
        epoch = 0
        modelName = model
        members = [ChatMember(kind: "model", name: "fingus", nick: nil, model: model)]
    }

    // MARK: following a reply

    /// Ask again and again while a reply is being written, drawing it as far as it has got (the server's `writing`), and until the finished
    /// reply is among the messages. Leaving the chat stops asking; the reply carries on at the PC.
    private func follow(after sent: Int, id: String, _ t: Token) {
        following?.cancel()
        let started = Date()
        replying = true
        following = Task { [weak self] in
            while let self, !Task.isCancelled, (try? self.check(t)) != nil {
                do { try await self.fetch(id, t) } catch { break }
                let sawReply = self.wire.values.contains { $0.kind == "model" && $0.seq > sent }
                let busy = self.writing.isEmpty ? ((try? await self.session.api.busy(id)) ?? false) : true
                guard (try? self.check(t)) != nil else { break }
                if !ChatPollPlan.shouldContinue(writing: !self.writing.isEmpty, busy: busy, sawReply: sawReply, secondsSinceSend: Date().timeIntervalSince(started)) { break }
                try? await Task.sleep(nanoseconds: UInt64(ChatPollPlan.interval * 1_000_000_000))
            }
            if let self, (try? self.check(t)) != nil { self.replying = false }
        }
    }

    func stopReply() async {
        guard let id = roomID else { return }
        let t = token()
        do { try await session.api.stop(id) } catch { fail(ChatStopWords.stoppingReply, error, t) }
    }

    // MARK: the model, and the chat's name

    /// A new chat: which model it will start with, so it is shown above the box before anything is said.
    private func prepareNew() async {
        let t = token()
        guard let models = try? await session.api.models(), (try? check(t)) != nil else { return }
        modelChoices = ChatModelPick.choices(from: models, privacy: privacy, current: nil)
        if modelName == nil { modelName = ChatModelPick.pick(from: models, privacy: privacy) }
    }

    /// The chooser opens: the models Aero offers now, for this chat's privacy.
    func loadChoices() async {
        let t = token()
        do {
            let models = try await session.api.models()
            try check(t)
            modelChoices = ChatModelPick.choices(from: models, privacy: privacy, current: modelName)
        } catch is ChatStale {
            return
        } catch {
            fail(ChatStopWords.listingModels, error, t)
        }
    }

    /// Switch the model that answers. A chat not yet started only takes it for when it starts; a started one asks Aero, which refuses a model
    /// this person could not add themselves, and the answer is read again so what is shown is what Aero holds.
    func chooseModel(_ model: String) async {
        guard model != modelName, !changing else { return }
        guard let id = roomID else { modelName = model; return }
        changing = true
        stopped = nil
        let t = token()
        defer { if (try? check(t)) != nil { changing = false } }
        do {
            try await session.api.setModel(room: id, member: modelMember, model: model)
            try check(t)
            modelName = model
            try await fetch(id, t)
        } catch is ChatStale {
            return
        } catch {
            fail(ChatStopWords.changingModel, error, t)
        }
    }

    /// Her own name for this chat. Empty clears it, and the PC names the chat again.
    func rename(to name: String) async {
        guard let id = roomID else { return }
        let words = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stopped = nil
        let t = token()
        do {
            try await session.api.renameRoom(id, to: words)
            try check(t)
            if words.isEmpty { title = session.firstWords[id] ?? ChatWords.newChat } else { title = words }
        } catch is ChatStale {
            return
        } catch {
            fail(ChatStopWords.renaming, error, t)
        }
    }

    // MARK: the one shape

    private func fail(_ doing: String, _ error: Error, _ t: Token) {
        session.note(error)
        guard (try? check(t)) != nil else { return }
        stopped = ChatStopWords.make(doing: doing, error: error)
        if let f = error as? ChatAPI.Failure, f == .locked, privacy == .locked { shut(); stopped = ChatStopWords.make(doing: doing, error: error) }
    }

    /// The key under a stopped note.
    func retry() async {
        guard let s = stopped else { return }
        if s.action == .retry {
            if draft.isEmpty { await load() } else { await send() }
        }
    }
}
