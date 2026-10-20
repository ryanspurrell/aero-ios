import Foundation
import CryptoKit
import Security

// The keys of a chat, in Swift, in the formats the page's `roomCrypto` (projects/messages/.../fingus-messages-ui/messages.js) and the
// store (fingus_messages_store.py) already use: a room's key is sealed to each device with ECDH (P-256) and HKDF-SHA256 into AES-GCM; a
// message is AES-GCM under the room's key and signed by its sending device (ECDSA P-256 over SHA-256). Nothing here is a new format; a
// message this file writes must be one the page opens, and the other way round. No server change is needed or made.
//
// Byte forms, as WebCrypto gives them and as CryptoKit reads them:
// - a public key travels as the 65-byte uncompressed point (x963Representation), base64url without padding;
// - an AES-GCM result is the ciphertext followed by the 16-byte tag (CryptoKit keeps them apart, so they are joined and split here);
// - an ECDSA signature is the 64 bytes r then s (rawRepresentation).

/// Base64url without padding, the only spelling the store accepts for keys, ivs, ciphertexts and signatures (its `B64` check). Decoding is
/// strict for the same reason: a character outside the alphabet, padding, a length no encoder makes, or trailing bits that are not zero is
/// refused, so the app never accepts a spelling the store would have refused.
enum ChatBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        for u in text.utf8 {
            let ok = (u >= 65 && u <= 90) || (u >= 97 && u <= 122) || (u >= 48 && u <= 57) || u == 45 || u == 95
            if !ok { return nil }
        }
        if text.utf8.count % 4 == 1 { return nil }
        var t = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let data = Data(base64Encoded: t), encode(data) == text else { return nil }
        return data
    }
}

enum ChatCryptoError: Error, Equatable {
    case badEncoding, badKey, badLength, notVerified, cannotOpen
}

/// The Keychain could not be read or written, or what it holds is not a device. Never answered by making a new device: the store treats a
/// device id and its keys as one thing, and seals addressed to the old one would be stranded.
enum ChatKeyError: Error, Equatable {
    case unreadable(Int32), notSaved(Int32), corrupt
}

/// A key the page can seal a room's key to: another device's public keys.
struct ChatDeviceKeys: Equatable {
    var device: String
    var ecdh: String          // base64url, 65 bytes
    var personID: String?
}

/// This phone as a device of the signed-in person. A device is its keys: new keys are a new device (the store refuses the same id with other keys).
/// On a phone the private keys live in the Secure Enclave and cannot be read out (only an opaque blob usable on this phone is kept); where there
/// is no Secure Enclave (the Simulator, tests) ordinary CryptoKit keys are used. The two operations the page uses are all that is offered:
/// agreeing on a secret with another device's public key, and signing.
struct ChatDevice {
    let person: String
    let id: String
    let ecdhPublic: String
    let signPublic: String
    let agree: (P256.KeyAgreement.PublicKey) throws -> SharedSecret
    let signRaw: (Data) throws -> Data
    private let keptData: () throws -> Data
    /// Raw keys kept in the Keychain (made by an earlier build, or where there is no Secure Enclave), not Secure Enclave keys.
    let isSoftware: Bool

    init(person: String, id: String, ecdhPublic: String, signPublic: String,
         agree: @escaping (P256.KeyAgreement.PublicKey) throws -> SharedSecret, signRaw: @escaping (Data) throws -> Data, kept: @escaping () throws -> Data,
         isSoftware: Bool = false) {
        self.person = person; self.id = id; self.ecdhPublic = ecdhPublic; self.signPublic = signPublic
        self.agree = agree; self.signRaw = signRaw; self.keptData = kept; self.isSoftware = isSoftware
    }

    /// A device made by an earlier build with raw keys, on a phone that has a Secure Enclave: it keeps working as it is, and is moved to
    /// the Secure Enclave only by `ChatSession` when that loses nothing (see `ChatSession.renewIfSafe`).
    var canMoveToEnclave: Bool { isSoftware && SecureEnclave.isAvailable }

    /// What is kept on the phone: the id and an opaque or raw form of each key, tagged with which.
    private struct Kept: Codable { var v: Int; var id: String; var kind: String; var ecdh: String; var sign: String }

    func kept() throws -> Data { try keptData() }

    static func software(person: String, id: String, ecdh: P256.KeyAgreement.PrivateKey, sign: P256.Signing.PrivateKey) -> ChatDevice {
        ChatDevice(person: person, id: id,
                   ecdhPublic: ChatBase64.encode(ecdh.publicKey.x963Representation), signPublic: ChatBase64.encode(sign.publicKey.x963Representation),
                   agree: { try ecdh.sharedSecretFromKeyAgreement(with: $0) },
                   signRaw: { try sign.signature(for: $0).rawRepresentation },
                   kept: { try JSONEncoder().encode(Kept(v: 1, id: id, kind: "software", ecdh: ChatBase64.encode(ecdh.rawRepresentation), sign: ChatBase64.encode(sign.rawRepresentation))) },
                   isSoftware: true)
    }

    static func enclave(person: String, id: String, ecdh: SecureEnclave.P256.KeyAgreement.PrivateKey, sign: SecureEnclave.P256.Signing.PrivateKey) -> ChatDevice {
        ChatDevice(person: person, id: id,
                   ecdhPublic: ChatBase64.encode(ecdh.publicKey.x963Representation), signPublic: ChatBase64.encode(sign.publicKey.x963Representation),
                   agree: { try ecdh.sharedSecretFromKeyAgreement(with: $0) },
                   signRaw: { try sign.signature(for: $0).rawRepresentation },
                   kept: { try JSONEncoder().encode(Kept(v: 1, id: id, kind: "enclave", ecdh: ChatBase64.encode(ecdh.dataRepresentation), sign: ChatBase64.encode(sign.dataRepresentation))) })
    }

    /// A new device: a random 12-byte id (as the page makes it) and two new key pairs, in the Secure Enclave when there is one.
    static func make(person: String) throws -> ChatDevice {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let id = ChatBase64.encode(Data(bytes))
        if SecureEnclave.isAvailable {
            return enclave(person: person, id: id, ecdh: try SecureEnclave.P256.KeyAgreement.PrivateKey(), sign: try SecureEnclave.P256.Signing.PrivateKey())
        }
        return software(person: person, id: id, ecdh: P256.KeyAgreement.PrivateKey(), sign: P256.Signing.PrivateKey())
    }

    /// What `restore` found: the device that was kept, which is used as it is (raw keys too, on a phone with a Secure Enclave: they are moved
    /// to it only when that loses nothing, never by replacing them here).
    enum Restored {
        case device(ChatDevice)
    }

    /// The device that was kept. Throws, and never returns a different one, when what is kept cannot be read as a device.
    static func restore(person: String, from data: Data) throws -> Restored {
        struct Legacy: Codable { var id: String; var ecdh: String; var sign: String }
        var kind = "", id = "", ecdhText = "", signText = ""
        if let k = try? JSONDecoder().decode(Kept.self, from: data), k.v == 1 {
            kind = k.kind; id = k.id; ecdhText = k.ecdh; signText = k.sign
        } else if let l = try? JSONDecoder().decode(Legacy.self, from: data) {
            kind = "software"; id = l.id; ecdhText = l.ecdh; signText = l.sign
        } else {
            throw ChatKeyError.corrupt
        }
        guard let e = ChatBase64.decode(ecdhText), let s = ChatBase64.decode(signText) else { throw ChatKeyError.corrupt }
        do {
            switch kind {
            case "software":
                return .device(software(person: person, id: id, ecdh: try P256.KeyAgreement.PrivateKey(rawRepresentation: e), sign: try P256.Signing.PrivateKey(rawRepresentation: s)))
            case "enclave":
                return .device(enclave(person: person, id: id, ecdh: try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: e), sign: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: s)))
            default:
                throw ChatKeyError.corrupt
            }
        } catch {
            throw ChatKeyError.corrupt
        }
    }
}

/// One sealed key as the room answer lists it (`seals` in GET /rooms/<id>.json).
struct ChatSeal: Codable, Equatable {
    var epoch: Int
    var byPerson: String
    var byDevice: String
    var iv: String
    var ct: String
    enum CodingKeys: String, CodingKey { case epoch, iv, ct; case byPerson = "by_person"; case byDevice = "by_device" }
}

/// A room's key sealed to one device, as /rooms/new takes it (`seals`).
struct ChatSealOut: Codable, Equatable {
    var epoch: Int
    var person: String
    var device: String
    var iv: String
    var ct: String
}

/// What a message is sealed as when it is sent: the three fields /rooms/<id>/send takes.
struct ChatSealed: Equatable {
    var iv: String
    var ct: String
    var sig: String
}

enum ChatCrypto {
    // MARK: the key a seal uses

    /// The key that locks a room key to one device: ECDH between this device and the other, then HKDF-SHA256 with the salt "<room>|<epoch>" and
    /// the info "fingus-messages-room-key" (the page's `kek`).
    static func kek(device: ChatDevice, theirs: String, room: String, epoch: Int) throws -> SymmetricKey {
        guard let raw = ChatBase64.decode(theirs) else { throw ChatCryptoError.badEncoding }
        guard let pub = try? P256.KeyAgreement.PublicKey(x963Representation: raw) else { throw ChatCryptoError.badKey }
        let secret = try device.agree(pub)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("\(room)|\(epoch)".utf8),
                                              sharedInfo: Data("fingus-messages-room-key".utf8), outputByteCount: 32)
    }

    // MARK: AES-GCM in the page's shape (ciphertext then tag)

    /// `iv` is for tests that must produce exact bytes; the app always lets a fresh one be made.
    static func lock(_ plain: Data, key: SymmetricKey, aad: String, iv: Data? = nil) throws -> (iv: Data, ct: Data) {
        let nonce = try iv.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        let box = try AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: Data(aad.utf8))
        return (Data(nonce), box.ciphertext + box.tag)
    }

    static func unlock(iv: String, ct: String, key: SymmetricKey, aad: String) throws -> Data {
        guard let ivData = ChatBase64.decode(iv), let joined = ChatBase64.decode(ct), joined.count >= 16 else { throw ChatCryptoError.badEncoding }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: ivData), ciphertext: joined.dropLast(16), tag: joined.suffix(16))
            return try AES.GCM.open(box, using: key, authenticating: Data(aad.utf8))
        } catch {
            throw ChatCryptoError.cannotOpen
        }
    }

    // MARK: a room's key

    /// A room key is exactly 32 bytes (`fresh` makes 32; the spec has no other).
    static func roomKey(_ raw: Data) throws -> SymmetricKey {
        guard raw.count == 32 else { throw ChatCryptoError.badLength }
        return SymmetricKey(data: raw)
    }

    /// A room's key as it was sealed to this device (the page's `unseal`). `sealerEcdh` is the public key of the device that sealed it
    /// (`by_device` in the seal, found in the answer's `devices`).
    static func unseal(room: String, seal: ChatSeal, sealerEcdh: String, device: ChatDevice) throws -> SymmetricKey {
        let key = try kek(device: device, theirs: sealerEcdh, room: room, epoch: seal.epoch)
        let raw = try unlock(iv: seal.iv, ct: seal.ct, key: key, aad: aad(room: room, epoch: seal.epoch, person: device.person, device: device.id))
        return try roomKey(raw)
    }

    /// A new room's key, sealed to every device given (the page's `seal`, with `fresh` for the key). `ivs` is for tests; the app passes none.
    static func seal(room: String, epoch: Int, key: SymmetricKey, to devices: [ChatDeviceKeys], person fallback: String, from device: ChatDevice, ivs: [Data]? = nil) throws -> [ChatSealOut] {
        let raw = key.withUnsafeBytes { Data($0) }
        guard raw.count == 32 else { throw ChatCryptoError.badLength }
        var out: [ChatSealOut] = []
        for (i, d) in devices.enumerated() {
            let person = d.personID ?? fallback
            let wrap = try kek(device: device, theirs: d.ecdh, room: room, epoch: epoch)
            let sealed = try lock(raw, key: wrap, aad: aad(room: room, epoch: epoch, person: person, device: d.device), iv: ivs?[i])
            out.append(ChatSealOut(epoch: epoch, person: person, device: d.device, iv: ChatBase64.encode(sealed.iv), ct: ChatBase64.encode(sealed.ct)))
        }
        return out
    }

    static func freshKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    /// "r" and 16 hex digits, as the page makes a room's id (the store checks it).
    static func roomID() -> String {
        "r" + (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // MARK: messages

    /// A JSON string exactly as `JSON.stringify` writes it: quotes, backslash and control characters escaped (\b \f \n \r \t, else \u00xx in
    /// lower case); a slash and every other character, non-ASCII included, written as it is.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for u in text.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    /// The bytes sealed for a message: `{"t":<text>}` and then any extra whole-number keys in order, as `JSON.stringify(Object.assign({t}, extra))`.
    static func plaintext(text: String, extra: [(String, Int)] = []) -> Data {
        var s = "{\"t\":" + jsonString(text)
        for (k, v) in extra { s += "," + jsonString(k) + ":" + String(v) }
        return Data((s + "}").utf8)
    }

    /// What a message is signed over: "room|epoch|sender|device|iv|ct" (the page's `signed`, the store's `signed_part`).
    static func signedPart(room: String, epoch: Int, sender: String, device: String, iv: String, ct: String) -> Data {
        Data("\(room)|\(epoch)|\(sender)|\(device)|\(iv)|\(ct)".utf8)
    }

    /// Seal a message under the room's key, signed by this device (the page's `encrypt`). `iv` is for tests only.
    static func encrypt(room: String, epoch: Int, key: SymmetricKey, text: String, extra: [(String, Int)] = [], device: ChatDevice, iv: Data? = nil) throws -> ChatSealed {
        let sealed = try lock(plaintext(text: text, extra: extra), key: key, aad: aad(room: room, epoch: epoch, person: device.person, device: device.id), iv: iv)
        let ivs = ChatBase64.encode(sealed.iv), ct = ChatBase64.encode(sealed.ct)
        let sig = try device.signRaw(signedPart(room: room, epoch: epoch, sender: device.person, device: device.id, iv: ivs, ct: ct))
        return ChatSealed(iv: ivs, ct: ct, sig: ChatBase64.encode(sig))
    }

    /// Whether `sig` is the signing device's over `signed`.
    static func verify(signPublic: String, sig: String, signed: Data) -> Bool {
        guard let pubRaw = ChatBase64.decode(signPublic), let sigRaw = ChatBase64.decode(sig),
              let pub = try? P256.Signing.PublicKey(x963Representation: pubRaw), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigRaw) else { return false }
        return pub.isValidSignature(signature, for: signed)
    }

    /// A message's body, only if its signature is its sending device's (the page's `openMsg`). The body is the JSON the sender sealed: `t` is
    /// the text; other keys (a reaction `re`, attachments `a`, steps `k`) are the page's and are read only as far as the screen draws them.
    static func open(room: String, epoch: Int, sender: String, device: String, iv: String, ct: String, sig: String, key: SymmetricKey, signPublic: String) throws -> [String: Any] {
        guard ChatBase64.decode(iv) != nil, ChatBase64.decode(ct) != nil, ChatBase64.decode(sig) != nil, ChatBase64.decode(signPublic) != nil else { throw ChatCryptoError.badEncoding }
        guard verify(signPublic: signPublic, sig: sig, signed: signedPart(room: room, epoch: epoch, sender: sender, device: device, iv: iv, ct: ct)) else { throw ChatCryptoError.notVerified }
        let plain = try unlock(iv: iv, ct: ct, key: key, aad: aad(room: room, epoch: epoch, person: sender, device: device))
        guard let body = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw ChatCryptoError.cannotOpen }
        return body
    }

    /// A live payload (a draft being written) or a room's notes box: sealed under the room key with a given AAD and not signed. Authenticated
    /// by the tag alone. Returns the JSON object.
    static func openSealed(iv: String, ct: String, key: SymmetricKey, aad: String) throws -> [String: Any] {
        let plain = try unlock(iv: iv, ct: ct, key: key, aad: aad)
        guard let body = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw ChatCryptoError.cannotOpen }
        return body
    }

    /// The additional data of a seal or a message: "room|epoch|person|device" (a seal's person is the one it is sealed to; a message's the sender).
    static func aad(room: String, epoch: Int, person: String, device: String) -> String { "\(room)|\(epoch)|\(person)|\(device)" }

    /// The additional data of a live payload: "room|epoch|sender|device" (the sender's name, and the PC's device).
    static func liveAAD(room: String, epoch: Int, sender: String, device: String) -> String { "\(room)|\(epoch)|\(sender)|\(device)" }

    /// The words so far of a reply being written, only if they open under the room key with exactly that additional data. nil when the payload
    /// is another kind (a typing mark, an activity) or names another room.
    static func openLive(room: String, live: ChatLiveWire, key: SymmetricKey) throws -> String? {
        if let named = live.room, named != room { return nil }
        let body = try openSealed(iv: live.iv, ct: live.ct, key: key, aad: liveAAD(room: room, epoch: live.epoch, sender: live.sender, device: live.device))
        return body["d"] as? String
    }

    // MARK: the safety code

    /// Twenty digits that two people can read to each other to see that they were given the same keys (the page's `roomCrypto.code`): the
    /// devices' "ecdh+sign" joined, sorted, joined with "|", SHA-256, the first nine bytes as a number, its last twenty digits, in groups of five.
    static func safetyCode(_ devices: [(ecdh: String, sign: String)]) -> String {
        guard !devices.isEmpty else { return "" }
        let joined = devices.map { $0.ecdh + $0.sign }.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }.joined(separator: "|")
        var number = Array(SHA256.hash(data: Data(joined.utf8)).prefix(9))
        // decimal digits of the 72-bit number by repeated division by ten (no big integer is needed)
        var digits: [Character] = []
        while number.contains(where: { $0 != 0 }) {
            var carry = 0
            for i in number.indices {
                let cur = carry * 256 + Int(number[i])
                number[i] = UInt8(cur / 10)
                carry = cur % 10
            }
            digits.append(Character(String(carry)))
        }
        var text = String(digits.reversed())
        if text.count > 20 { text = String(text.suffix(20)) }
        text = String(repeating: "0", count: 20 - text.count) + text
        return stride(from: 0, to: 20, by: 5).map { i in
            let a = text.index(text.startIndex, offsetBy: i)
            return String(text[a..<text.index(a, offsetBy: 5)])
        }.joined(separator: " ")
    }
}

// MARK: where the device's keys are kept

/// Where this phone's device (opaque Secure Enclave blobs, or raw keys where there is none) is kept. The Keychain on the phone; a dictionary in
/// tests. `load` answers nil only when nothing is kept; any other failure throws.
protocol ChatKeyStore {
    func load(person: String) throws -> Data?
    func save(_ data: Data, person: String) throws
    /// Nothing is kept for `person` any more (not an error if nothing was).
    func forget(person: String) throws
}

struct KeychainChatKeyStore: ChatKeyStore {
    private let service = "aero.chat.device"

    private func query(_ person: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: person]
    }

    func load(person: String) throws -> Data? {
        var q = query(person)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw ChatKeyError.unreadable(status) }
        // an item made by an earlier build was readable after the first unlock; it is moved to unlocked-only
        let moved = SecItemUpdate(query(person) as CFDictionary, [kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as CFDictionary)
        guard moved == errSecSuccess else { throw ChatKeyError.notSaved(moved) }
        return data
    }

    func forget(person: String) throws {
        let status = SecItemDelete(query(person) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw ChatKeyError.notSaved(status) }
    }

    func save(_ data: Data, person: String) throws {
        var status = SecItemUpdate(query(person) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(person)
            q[kSecValueData as String] = data
            // readable only while the phone is unlocked, and never copied to another phone: a device is this phone
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ChatKeyError.notSaved(status) }
    }
}

final class MemoryChatKeyStore: ChatKeyStore {
    private var kept: [String: Data] = [:]
    func load(person: String) throws -> Data? { kept[person] }
    func save(_ data: Data, person: String) throws { kept[person] = data }
    func forget(person: String) throws { kept[person] = nil }
}

/// The device made to take the place of an earlier build's (raw keys), kept apart under its own name beside the person's device until Aero says
/// it can open everything the old one can and takes the old one out; never read as the person's device, and never used before then. It is
/// kept (its private keys too) from the moment it is registered, because the chats it is to be given can only be opened with them.
enum ChatNextDevice {
    static func name(_ person: String) -> String { person + "#next" }

    static func load(person: String, in store: ChatKeyStore) -> ChatDevice? {
        guard let data = try? store.load(person: name(person)), case .device(let d)? = try? ChatDevice.restore(person: person, from: data) else { return nil }
        return d
    }

    static func keep(_ device: ChatDevice, in store: ChatKeyStore) throws {
        try store.save(try device.kept(), person: name(device.person))
    }

    static func clear(person: String, in store: ChatKeyStore) {
        try? store.forget(person: name(person))
    }
}

enum ChatDeviceKeeper {
    /// This phone's device for `person`: the one kept, or, only when nothing at all is kept, a new one made and kept before it is used. A
    /// failed read or a kept device that cannot be read throws; it is never replaced. A device made by an earlier build (raw keys) is
    /// kept as it is even where there is a Secure Enclave: replacing it here would leave the chats only it could open closed for good.
    static func device(for person: String, in store: ChatKeyStore = KeychainChatKeyStore()) throws -> ChatDevice {
        if let data = try store.load(person: person) {
            switch try ChatDevice.restore(person: person, from: data) {
            case .device(let d): return d
            }
        }
        let made = try ChatDevice.make(person: person)
        try store.save(try made.kept(), person: person)
        return made
    }

    /// Keep `fresh` in the place of `old`, which is the one step that discards the old keys. Called only after Aero has taken the old
    /// device out of the person's list, which it does (in one step with its check) only when `fresh` already holds a seal of every key the
    /// old one does; never before: until then the old keys are the only way to open what it holds. A failed save throws and leaves the old
    /// keys kept. The noted next device is cleared once `fresh` is the one kept.
    static func replace(_ old: ChatDevice, with fresh: ChatDevice, in store: ChatKeyStore) throws {
        try store.save(try fresh.kept(), person: old.person)
        ChatNextDevice.clear(person: old.person, in: store)
    }

    /// Aero says this phone's device was removed from the person's list and it still has its keys: it is not taken back as it was. It starts
    /// again with the device noted for the move to the Secure Enclave if there is one, else a new one, kept in the place of the old.
    static func startAgain(for person: String, in store: ChatKeyStore) throws -> ChatDevice {
        let next = try ChatNextDevice.load(person: person, in: store) ?? ChatDevice.make(person: person)
        try store.save(try next.kept(), person: person)
        ChatNextDevice.clear(person: person, in: store)
        return next
    }
}


/// Before the old device is taken out for a new one, whether the new one can really open what the old one can. Aero holds the seals but
/// cannot open them, so it can only check that a row exists; this opens each one here.
enum ChatRenewalCheck {
    /// Asked of a room answer to leave its messages out: past any sequence number.
    static let noMessages = 1_000_000_000

    /// How many of the old device's room keys the new device does not get identically. Each pair is one chat's answer as asked for the old
    /// device and as asked for the new one. A seal the old device itself cannot open is not counted: there is no key to compare it to.
    static func unopened(_ pairs: [(ChatRoomAnswer, ChatRoomAnswer)], old: ChatDevice, fresh: ChatDevice) -> Int {
        var bad = 0
        for (theirs, mine) in pairs {
            for seal in theirs.seals {
                guard let key = opened(seal, in: theirs, by: old) else { continue }
                guard let got = mine.seals.first(where: { $0.epoch == seal.epoch }).flatMap({ opened($0, in: mine, by: fresh) }),
                      raw(got) == raw(key) else { bad += 1; continue }
            }
        }
        return bad
    }

    private static func opened(_ seal: ChatSeal, in answer: ChatRoomAnswer, by device: ChatDevice) -> SymmetricKey? {
        guard let sealer = (answer.devices[seal.byPerson] ?? []).first(where: { $0.device == seal.byDevice }) else { return nil }
        return try? ChatCrypto.unseal(room: answer.id, seal: seal, sealerEcdh: sealer.ecdh, device: device)
    }

    private static func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
}
