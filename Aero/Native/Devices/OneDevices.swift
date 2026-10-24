import Foundation

// One device as Aero's PC lists it (`one-devices.json`): one row per device with its parts inside: its sign-ins, its chat keys (trusted or
// waiting) and its file key (Core's). Approving, merging and removing act on all parts together, after she confirms. Specified in
// Systems/OneDevice.lean (a device is one row; every part is in exactly one row), Systems/OneDeviceRemoval.lean (a device used lately, or never
// matched, is removed only after "Confirm it's not yours", which sends back the evidence she was shown; the removal is a journal that carries on
// from where it stopped) and Systems/DeviceApprovalCode.lean (an approval names the code of the keys she saw on both screens). The rules here
// follow the PC's code (aero_devices_one.py, aero_web.py `one_devices*`), which is the authority; this file only reads what it says.

private extension KeyedDecodingContainer {
    /// A field that may be missing or odd in an older or newer PC: its fallback, never a failure of the whole list.
    func get<T: Decodable>(_ key: Key, _ fallback: T) -> T { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback }
    func maybe<T: Decodable>(_ key: Key) -> T? { ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) }
}

/// A sign-in Aero remembers this device by (a browser, or this app's web view).
struct OneSignIn: Decodable, Equatable, Identifiable {
    var id: String
    var label: String
    var agent: String
    var seen: Double
    var cut: Bool
    enum CodingKeys: String, CodingKey { case id, label, agent, seen, cut }
    init(id: String, label: String = "", agent: String = "", seen: Double = 0, cut: Bool = false) {
        self.id = id; self.label = label; self.agent = agent; self.seen = seen; self.cut = cut
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.get(.id, ""); label = c.get(.label, ""); agent = c.get(.agent, ""); seen = c.get(.seen, 0)
        cut = c.contains(.cut) && ((try? c.decodeNil(forKey: .cut)) == false)
    }
    var shownName: String { agent.isEmpty ? (label.isEmpty ? "A browser" : label) : agent }
}

/// A chat key of the device: trusted, or waiting for a device she already uses to approve it. A waiting one carries the code both screens show.
struct OneChatKey: Decodable, Equatable, Identifiable {
    var device: String
    var name: String?
    var label: String?
    var added: Double?
    var trusted: Bool
    var approvedBy: String?
    var ecdh: String
    var sign: String
    var code: String?
    var codeShown: String?
    var id: String { device }
    enum CodingKeys: String, CodingKey {
        case device, name, label, added, trusted, ecdh, sign, code
        case approvedBy = "approved_by", codeShown = "code_shown"
    }
    init(device: String, name: String? = nil, label: String? = nil, added: Double? = nil, trusted: Bool, approvedBy: String? = nil,
         ecdh: String, sign: String, code: String? = nil, codeShown: String? = nil) {
        self.device = device; self.name = name; self.label = label; self.added = added; self.trusted = trusted; self.approvedBy = approvedBy
        self.ecdh = ecdh; self.sign = sign; self.code = code; self.codeShown = codeShown
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = c.get(.device, ""); name = c.maybe(.name); label = c.maybe(.label); added = c.maybe(.added)
        trusted = c.get(.trusted, false); approvedBy = c.maybe(.approvedBy)
        ecdh = c.get(.ecdh, ""); sign = c.get(.sign, ""); code = c.maybe(.code); codeShown = c.maybe(.codeShown)
    }
}

/// The device's key in Core (what its files are locked to).
struct OneFileKey: Decodable, Equatable, Identifiable {
    var device: String
    var label: String?
    var kind: String?
    var added: Double?
    var used: Double?
    var id: String { device }
    enum CodingKeys: String, CodingKey { case device, label, kind, added, used }
    init(device: String, label: String? = nil, kind: String? = nil, added: Double? = nil, used: Double? = nil) {
        self.device = device; self.label = label; self.kind = kind; self.added = added; self.used = used
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        device = c.get(.device, ""); label = c.maybe(.label); kind = c.maybe(.kind); added = c.maybe(.added); used = c.maybe(.used)
    }
}

struct OneParts: Decodable, Equatable {
    var session: [OneSignIn] = []
    var chat: [OneChatKey] = []
    var key: [OneFileKey] = []
    enum CodingKeys: String, CodingKey { case session, chat, key }
    init(session: [OneSignIn] = [], chat: [OneChatKey] = [], key: [OneFileKey] = []) { self.session = session; self.chat = chat; self.key = key }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        session = c.get(.session, []); chat = c.get(.chat, []); key = c.get(.key, [])
    }
}

/// The evidence she is shown before a device is removed, and what she sends back to confirm it: when it was last in use, and whether it was ever
/// matched to a device she is using (the PC compares the two, so it is sent exactly as it came).
struct OneInfo: Codable, Equatable {
    var seen: Int
    var confirmed: Bool
}

/// A removal under way: the PC writes "removing" on the device, then goes step by step and records each; a step that fails stops there, and the
/// next ask carries on.
struct OneRemoving: Decodable, Equatable {
    var done: [String]
    var stuck: String?
    enum CodingKeys: String, CodingKey { case done, stuck }
    private struct Stuck: Decodable { var why: String? }
    init(done: [String] = [], stuck: String? = nil) { self.done = done; self.stuck = stuck }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        done = c.get(.done, [])
        stuck = (c.maybe(.stuck) as Stuck?)?.why ?? c.maybe(.stuck)
    }
}

struct OneDevice: Decodable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: String
    /// The device she is using now (its sign-in or its chat key is this one's).
    var this: Bool
    /// One of its chat keys is not approved yet.
    var waiting: Bool
    var seen: Double
    var canRemove: Bool
    var whyNot: String
    var info: OneInfo
    /// Why it is not removed in one step (empty when it is).
    var confirmFirst: [String]
    var removing: OneRemoving?
    var parts: OneParts
    enum CodingKeys: String, CodingKey {
        case id, name, kind, this, waiting, seen, info, removing, parts
        case canRemove = "can_remove", whyNot = "why_not", confirmFirst = "confirm_first"
    }
    init(id: String, name: String, kind: String = "Device", this: Bool = false, waiting: Bool = false, seen: Double = 0, canRemove: Bool = true,
         whyNot: String = "", info: OneInfo = OneInfo(seen: 0, confirmed: true), confirmFirst: [String] = [], removing: OneRemoving? = nil,
         parts: OneParts = OneParts()) {
        self.id = id; self.name = name; self.kind = kind; self.this = this; self.waiting = waiting; self.seen = seen; self.canRemove = canRemove
        self.whyNot = whyNot; self.info = info; self.confirmFirst = confirmFirst; self.removing = removing; self.parts = parts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.get(.id, ""); name = c.get(.name, ""); kind = c.get(.kind, "Device"); this = c.get(.this, false); waiting = c.get(.waiting, false)
        seen = c.get(.seen, 0); canRemove = c.get(.canRemove, false); whyNot = c.get(.whyNot, "")
        info = c.get(.info, OneInfo(seen: 0, confirmed: false)); confirmFirst = c.get(.confirmFirst, [])
        removing = c.maybe(.removing); parts = c.get(.parts, OneParts())
    }
    var shownName: String { name.isEmpty ? "A device" : name }
}

/// Two rows that may be one device, with the evidence; nothing is merged on a guess.
struct OneMaybeSame: Decodable, Equatable {
    var a: String
    var b: String
    var why: String
}

struct OneDevicesAnswer: Decodable, Equatable {
    var devices: [OneDevice]
    var maybeSame: [OneMaybeSame]
    /// The PC's clock in seconds: a signature is good only for a few minutes of its time.
    var now: Double
    enum CodingKeys: String, CodingKey { case devices, now; case maybeSame = "maybe_same" }
    init(devices: [OneDevice], maybeSame: [OneMaybeSame] = [], now: Double = 0) { self.devices = devices; self.maybeSame = maybeSame; self.now = now }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = c.get(.devices, []); maybeSame = c.get(.maybeSame, []); now = c.get(.now, Date().timeIntervalSince1970)
    }
}

/// Where a removal stands: gone, or which steps are done and what stopped the next.
struct OneRemoval: Decodable, Equatable {
    var gone: Bool
    var done: [String]
    var stuck: String?
    enum CodingKeys: String, CodingKey { case gone, done, stuck }
    private struct Stuck: Decodable { var why: String? }
    init(gone: Bool, done: [String] = [], stuck: String? = nil) { self.gone = gone; self.done = done; self.stuck = stuck }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gone = c.get(.gone, false); done = c.get(.done, [])
        stuck = (c.maybe(.stuck) as Stuck?)?.why ?? c.maybe(.stuck)
    }
}

/// What a removal call answers: how far it got, or (409) that she must first confirm it is not hers, seeing why and the evidence.
enum OneRemoveResult: Equatable {
    case progress(OneRemoval)
    case confirm(reasons: [String], info: OneInfo)

    static func read(_ data: Data) -> OneRemoveResult? {
        struct Confirm: Decodable { var reasons: [String]?; var info: OneInfo? }
        struct Said: Decodable { var confirm: Confirm? }
        let said = try? JSONDecoder().decode(Said.self, from: data)
        if let c = said?.confirm, let info = c.info { return .confirm(reasons: c.reasons ?? [], info: info) }
        return (try? JSONDecoder().decode(OneRemoval.self, from: data)).map { .progress($0) }
    }
}

/// What the screen asks before a removal goes on: the device, why it is not removed in one step, and the evidence she confirms by tapping.
struct OneRemovalAsk: Equatable {
    var device: OneDevice
    var reasons: [String]
    var info: OneInfo
}

/// Two devices she may merge, and what was seen that makes them look alike (nil when she picked the pair herself).
struct OneMergeAsk: Equatable, Identifiable {
    var a: OneDevice
    var b: OneDevice
    var why: String?
    var id: String { a.id + "|" + b.id }
}

/// The plain rules of the Devices screen: what each row says, and what may be done to it.
enum OneDeviceListing {
    static func title(_ d: OneDevice, thisChat: String?) -> String {
        d.shownName + (isThisPhone(d, thisChat: thisChat) ? " (this phone)" : "")
    }

    /// This phone's own chat key is in the row.
    static func isThisPhone(_ d: OneDevice, thisChat: String?) -> Bool {
        guard let thisChat else { return false }
        return d.parts.chat.contains { $0.device == thisChat }
    }

    /// "Removing…", or the kind and what the device has: signed in, its chat keys approved or waiting, a file key.
    static func note(_ d: OneDevice) -> String {
        if let removing = d.removing { return DevicesWords.removingState + (removing.stuck.map { " " + $0 } ?? "") }
        var bits: [String] = []
        if !d.kind.isEmpty { bits.append(d.kind) }
        if !d.parts.session.isEmpty { bits.append(DevicesWords.signedIn) }
        if !d.parts.chat.isEmpty { bits.append(d.waiting ? DevicesWords.waiting : DevicesWords.chatKeys) }
        if !d.parts.key.isEmpty { bits.append(DevicesWords.fileKey) }
        return bits.joined(separator: " \u{00B7} ")
    }

    /// "1 sign-in, 2 chat keys, 1 file key": what goes with the device.
    static func has(_ d: OneDevice) -> String {
        func one(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        return [d.parts.session.isEmpty ? "" : one(d.parts.session.count, "sign-in"),
                d.parts.chat.isEmpty ? "" : one(d.parts.chat.count, "chat key"),
                d.parts.key.isEmpty ? "" : one(d.parts.key.count, "file key")].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// This phone has a chat key that is approved (only such a phone approves or removes another device's chat keys).
    static func iAmTrusted(_ devices: [OneDevice], thisChat: String?) -> Bool {
        guard let thisChat else { return false }
        return devices.contains { $0.parts.chat.contains { $0.device == thisChat && $0.trusted } }
    }

    /// The waiting chat keys of a device that this phone may approve: not its own, and only from a phone that is itself approved.
    static func approvable(_ d: OneDevice, devices: [OneDevice], thisChat: String?) -> [OneChatKey] {
        guard iAmTrusted(devices, thisChat: thisChat), d.removing == nil else { return [] }
        return d.parts.chat.filter { !$0.trusted && $0.device != thisChat }
    }

    /// Why a device cannot be removed from here, in words; nil when it can. A removal that has begun can always be carried on. This phone is not
    /// removed from itself (its chats would lose their keys under it); the PC says why for the others (the device in use, the only approved one,
    /// the PC itself, one stopped at the door).
    static func removalBlocked(_ d: OneDevice, devices: [OneDevice], thisChat: String?) -> String? {
        if !iAmTrusted(devices, thisChat: thisChat) { return DevicesWords.removeNeedsApproval }
        if isThisPhone(d, thisChat: thisChat) { return DevicesWords.removeFromAnother }
        if d.removing != nil { return nil }
        if !d.canRemove { return d.whyNot.isEmpty ? DevicesWords.removeNotNow : d.whyNot }
        return nil
    }

    /// "3 minutes ago", or "never" for a device that has not been seen.
    static func when(_ seconds: Double, now: Date = Date(), locale: Locale = .current) -> String {
        if seconds <= 0 { return DevicesWords.never }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .full
        return f.localizedString(for: Date(timeIntervalSince1970: seconds), relativeTo: now)
    }

    /// The code both screens show for a waiting key, written as on a screen (the one this phone signs), nil when the PC's own code for the same
    /// keys is different (then nothing is approved: the keys it lists are not the keys the code was made from).
    static func shownCode(_ k: OneChatKey) -> String? {
        let code = DeviceCode.code(ecdh: k.ecdh, sign: k.sign)
        if let said = k.code, !said.isEmpty, said != code { return nil }
        return DeviceCode.shown(code)
    }
}
