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

/// Base64url without padding, the form every key, iv, ciphertext and signature travels in.
enum ChatBase64 {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ text: String) -> Data? {
        var t = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

enum ChatCryptoError: Error, Equatable {
    case badEncoding, badKey, notVerified, cannotOpen
}

/// A key the page can seal a room's key to: another device's public keys.
struct ChatDeviceKeys: Equatable {
    var device: String
    var ecdh: String          // base64url, 65 bytes
    var personID: String?
}

/// This phone as a device of the signed-in person. A device is its keys: new keys are a new device (the store refuses the same id with other keys).
struct ChatDevice {
    let person: String
    let id: String
    let ecdh: P256.KeyAgreement.PrivateKey
    let sign: P256.Signing.PrivateKey

    var ecdhPublic: String { ChatBase64.encode(ecdh.publicKey.x963Representation) }
    var signPublic: String { ChatBase64.encode(sign.publicKey.x963Representation) }

    /// A new device: a random 12-byte id (as the page makes it) and two new key pairs.
    static func make(person: String) -> ChatDevice {
        var bytes = [UInt8](repeating: 0, count: 12)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return ChatDevice(person: person, id: ChatBase64.encode(Data(bytes)), ecdh: P256.KeyAgreement.PrivateKey(), sign: P256.Signing.PrivateKey())
    }

    /// What is kept on the phone: the id and both private keys' raw bytes.
    private struct Kept: Codable { var id: String; var ecdh: String; var sign: String }

    func kept() throws -> Data {
        try JSONEncoder().encode(Kept(id: id, ecdh: ChatBase64.encode(ecdh.rawRepresentation), sign: ChatBase64.encode(sign.rawRepresentation)))
    }

    static func restore(person: String, from data: Data) -> ChatDevice? {
        guard let k = try? JSONDecoder().decode(Kept.self, from: data),
              let e = ChatBase64.decode(k.ecdh), let s = ChatBase64.decode(k.sign),
              let ecdh = try? P256.KeyAgreement.PrivateKey(rawRepresentation: e),
              let sign = try? P256.Signing.PrivateKey(rawRepresentation: s) else { return nil }
        return ChatDevice(person: person, id: k.id, ecdh: ecdh, sign: sign)
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
        let secret = try device.ecdh.sharedSecretFromKeyAgreement(with: pub)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("\(room)|\(epoch)".utf8),
                                              sharedInfo: Data("fingus-messages-room-key".utf8), outputByteCount: 32)
    }

    // MARK: AES-GCM in the page's shape (ciphertext then tag)

    static func lock(_ plain: Data, key: SymmetricKey, aad: String) throws -> (iv: Data, ct: Data) {
        let nonce = AES.GCM.Nonce()
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

    /// A room's key as it was sealed to this device (the page's `unseal`). `sealerEcdh` is the public key of the device that sealed it
    /// (`by_device` in the seal, found in the answer's `devices`).
    static func unseal(room: String, seal: ChatSeal, sealerEcdh: String, device: ChatDevice) throws -> SymmetricKey {
        let key = try kek(device: device, theirs: sealerEcdh, room: room, epoch: seal.epoch)
        let raw = try unlock(iv: seal.iv, ct: seal.ct, key: key, aad: "\(room)|\(seal.epoch)|\(device.person)|\(device.id)")
        return SymmetricKey(data: raw)
    }

    /// A new room's key, sealed to every device given (the page's `seal`, with `fresh` for the key). Returns the key and the seals to send.
    static func seal(room: String, epoch: Int, key: SymmetricKey, to devices: [ChatDeviceKeys], person fallback: String, from device: ChatDevice) throws -> [ChatSealOut] {
        let raw = key.withUnsafeBytes { Data($0) }
        var out: [ChatSealOut] = []
        for d in devices {
            let person = d.personID ?? fallback
            let wrap = try kek(device: device, theirs: d.ecdh, room: room, epoch: epoch)
            let sealed = try lock(raw, key: wrap, aad: "\(room)|\(epoch)|\(person)|\(d.device)")
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

    /// What a message is signed over: "room|epoch|sender|device|iv|ct" (the page's `signed`, the store's `signed_part`).
    static func signedPart(room: String, epoch: Int, sender: String, device: String, iv: String, ct: String) -> Data {
        Data("\(room)|\(epoch)|\(sender)|\(device)|\(iv)|\(ct)".utf8)
    }

    /// Seal a message: {"t": text} under the room's key, signed by this device (the page's `encrypt`).
    static func encrypt(room: String, epoch: Int, key: SymmetricKey, text: String, device: ChatDevice) throws -> ChatSealed {
        let body = try JSONSerialization.data(withJSONObject: ["t": text])
        let sealed = try lock(body, key: key, aad: "\(room)|\(epoch)|\(device.person)|\(device.id)")
        let iv = ChatBase64.encode(sealed.iv), ct = ChatBase64.encode(sealed.ct)
        let sig = try device.sign.signature(for: signedPart(room: room, epoch: epoch, sender: device.person, device: device.id, iv: iv, ct: ct))
        return ChatSealed(iv: iv, ct: ct, sig: ChatBase64.encode(sig.rawRepresentation))
    }

    /// A message's body, only if its signature is the sending device's (the page's `openMsg`). The body is the JSON the sender sealed: `t` is
    /// the text; other keys (a reaction `re`, attachments `a`, steps `k`) are the page's and are read only as far as the screen draws them.
    static func open(room: String, epoch: Int, sender: String, device: String, iv: String, ct: String, sig: String, key: SymmetricKey, signPublic: String) throws -> [String: Any] {
        guard let pubRaw = ChatBase64.decode(signPublic), let sigRaw = ChatBase64.decode(sig) else { throw ChatCryptoError.badEncoding }
        guard let pub = try? P256.Signing.PublicKey(x963Representation: pubRaw), let signature = try? P256.Signing.ECDSASignature(rawRepresentation: sigRaw),
              pub.isValidSignature(signature, for: signedPart(room: room, epoch: epoch, sender: sender, device: device, iv: iv, ct: ct)) else { throw ChatCryptoError.notVerified }
        let plain = try unlock(iv: iv, ct: ct, key: key, aad: "\(room)|\(epoch)|\(sender)|\(device)")
        guard let body = try? JSONSerialization.jsonObject(with: plain) as? [String: Any] else { throw ChatCryptoError.cannotOpen }
        return body
    }
}

// MARK: where the device's keys are kept

/// Where this phone's device keys live. The Keychain on the phone; a plain dictionary in tests.
protocol ChatKeyStore {
    func load(person: String) -> Data?
    func save(_ data: Data, person: String)
}

struct KeychainChatKeyStore: ChatKeyStore {
    private let service = "aero.chat.device"

    private func query(_ person: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: person]
    }

    func load(person: String) -> Data? {
        var q = query(person)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func save(_ data: Data, person: String) {
        SecItemDelete(query(person) as CFDictionary)
        var q = query(person)
        q[kSecValueData as String] = data
        // readable after the first unlock, never copied to another phone: a device is this phone
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
}

final class MemoryChatKeyStore: ChatKeyStore {
    private var kept: [String: Data] = [:]
    func load(person: String) -> Data? { kept[person] }
    func save(_ data: Data, person: String) { kept[person] = data }
}

enum ChatDeviceKeeper {
    /// This phone's device for `person`: the one kept, or a new one made and kept. Two people signing in on one phone are two devices.
    static func device(for person: String, in store: ChatKeyStore = KeychainChatKeyStore()) -> ChatDevice {
        if let data = store.load(person: person), let device = ChatDevice.restore(person: person, from: data) { return device }
        let made = ChatDevice.make(person: person)
        if let data = try? made.kept() { store.save(data, person: person) }
        return made
    }
}
