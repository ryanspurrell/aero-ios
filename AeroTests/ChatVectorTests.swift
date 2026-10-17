import XCTest
import CryptoKit
@testable import Aero

/// The chat formats against the reference vectors (projects/messages/tests/chat_crypto_vectors.json, made by chat_crypto_vectors.py from invented
/// keys, and by the page's own roomCrypto under Node for "page_made"). Where the vector was made with a fixed IV this code must give the exact
/// bytes; where it was made with a random IV or an ECDSA signature (the page's), this code must accept it, never reproduce it. ECDSA
/// signatures made here are only verified, since another signature over the same bytes is also right.
final class ChatVectorTests: XCTestCase {
    private var v: [String: Any] = [:]
    private var room = ""

    override func setUpWithError() throws {
        let url = try XCTUnwrap(Bundle(for: ChatVectorTests.self).url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/chat_crypto"), "the vectors are not in the test bundle")
        v = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        room = ((v["room"] as? [String: Any])?["id"] as? String) ?? ""
    }

    // MARK: helpers

    private func dict(_ any: Any?) -> [String: Any] { (any as? [String: Any]) ?? [:] }
    private func str(_ d: [String: Any], _ k: String) -> String { (d[k] as? String) ?? "" }

    private func hex(_ text: String) -> Data {
        var out = Data()
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 2)
            out.append(UInt8(text[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    private func hexString(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func device(_ name: String) throws -> ChatDevice {
        let d = dict(dict(v["devices"])[name])
        let e = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(str(d, "ecdh_private_scalar_hex")))
        let s = try P256.Signing.PrivateKey(rawRepresentation: hex(str(d, "sign_private_scalar_hex")))
        let made = ChatDevice.software(person: str(d, "person"), id: str(d, "device"), ecdh: e, sign: s)
        XCTAssertEqual(made.ecdhPublic, str(d, "ecdh_public"))
        XCTAssertEqual(made.signPublic, str(d, "sign_public"))
        return made
    }

    private func roomKey(_ epoch: Int) throws -> SymmetricKey {
        try ChatCrypto.roomKey(hex(str(dict(v["room_keys_hex"]), String(epoch))))
    }

    private func bytes(_ k: SymmetricKey) -> Data { k.withUnsafeBytes { Data($0) } }

    // MARK: keys

    func testTheSharedSecretAndTheKeyThatLocksAKey() throws {
        let alice = try device("alice"), bob = try device("bob")
        let kd = dict(v["key_derivation"])
        let a2b = dict(kd["alice_to_bob"])
        let bobPub = try P256.KeyAgreement.PublicKey(x963Representation: XCTUnwrap(ChatBase64.decode(bob.ecdhPublic)))
        XCTAssertEqual(hexString(try alice.agree(bobPub).withUnsafeBytes { Data($0) }), str(a2b, "ecdh_shared_secret_x_hex"))
        XCTAssertEqual(hexString(bytes(try ChatCrypto.kek(device: alice, theirs: bob.ecdhPublic, room: room, epoch: 0))), str(a2b, "kek_hex"))
        XCTAssertEqual(hexString(bytes(try ChatCrypto.kek(device: alice, theirs: alice.ecdhPublic, room: room, epoch: 0))), str(dict(kd["alice_to_alice"]), "kek_hex"))
    }

    func testSealsAreTheExactBytesAndOpenToTheRoomKeys() throws {
        let people = ["alice": try device("alice"), "bob": try device("bob")]
        for seal in (v["seals"] as? [[String: Any]]) ?? [] {
            let sent = dict(seal["as_sent"])
            let epoch = (sent["epoch"] as? Int) ?? -1
            let sealer = try XCTUnwrap(people[str(seal, "sealed_by")])
            let to = try XCTUnwrap(people.values.first { $0.id == str(sent, "device") })
            let made = try ChatCrypto.seal(room: room, epoch: epoch, key: roomKey(epoch), to: [ChatDeviceKeys(device: to.id, ecdh: to.ecdhPublic, personID: str(sent, "person"))],
                                           person: sealer.person, from: sealer, ivs: [try XCTUnwrap(ChatBase64.decode(str(sent, "iv")))])
            XCTAssertEqual(made.first?.iv, str(sent, "iv"))
            XCTAssertEqual(made.first?.ct, str(sent, "ct"))
            XCTAssertEqual(made.first?.person, str(sent, "person"))
            let opened = try ChatCrypto.unseal(room: room, seal: ChatSeal(epoch: epoch, byPerson: str(seal, "by_person"), byDevice: str(seal, "by_device"), iv: str(sent, "iv"), ct: str(sent, "ct")),
                                               sealerEcdh: sealer.ecdhPublic, device: to)
            XCTAssertEqual(bytes(opened), bytes(try roomKey(epoch)))
        }
    }

    func testTheSealFromThePageItselfOpens() throws {
        let alice = try device("alice"), bob = try device("bob")
        let s = dict(dict(v["page_made"])["seal_alice_to_bob_epoch0"])
        let opened = try ChatCrypto.unseal(room: room, seal: ChatSeal(epoch: 0, byPerson: alice.person, byDevice: alice.id, iv: str(s, "iv"), ct: str(s, "ct")), sealerEcdh: alice.ecdhPublic, device: bob)
        XCTAssertEqual(bytes(opened), bytes(try roomKey(0)))
    }

    func testARoomKeyThatIsNot32BytesIsRefused() throws {
        let alice = try device("alice")
        let wrap = try ChatCrypto.kek(device: alice, theirs: alice.ecdhPublic, room: room, epoch: 0)
        let short = try ChatCrypto.lock(Data(repeating: 7, count: 31), key: wrap, aad: "\(room)|0|\(alice.person)|\(alice.id)")
        let seal = ChatSeal(epoch: 0, byPerson: alice.person, byDevice: alice.id, iv: ChatBase64.encode(short.iv), ct: ChatBase64.encode(short.ct))
        XCTAssertThrowsError(try ChatCrypto.unseal(room: room, seal: seal, sealerEcdh: alice.ecdhPublic, device: alice)) { XCTAssertEqual($0 as? ChatCryptoError, .badLength) }
        XCTAssertThrowsError(try ChatCrypto.roomKey(Data(repeating: 1, count: 16)))
    }

    // MARK: messages

    func testEveryMessageIsTheExactBytesAndItsSignatureVerifies() throws {
        let people = ["person-alice-0001": try device("alice"), "person-bob-0002": try device("bob")]
        for m in (v["messages"] as? [[String: Any]]) ?? [] {
            let name = str(m, "name")
            let epoch = (m["epoch"] as? Int) ?? -1
            let sender = try XCTUnwrap(people[str(m, "sender_id")])
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(str(m, "plaintext_json").utf8)) as? [String: Any])
            let extra = json.keys.filter { $0 != "t" }.sorted().map { ($0, (json[$0] as? Int) ?? 0) }
            let text = (json["t"] as? String) ?? ""
            // the plaintext, byte for byte as JSON.stringify wrote it
            XCTAssertEqual(hexString(ChatCrypto.plaintext(text: text, extra: extra)), str(m, "plaintext_hex"), name)
            // sealed with the vector's IV: the exact iv and ciphertext
            let made = try ChatCrypto.encrypt(room: room, epoch: epoch, key: roomKey(epoch), text: text, extra: extra, device: sender, iv: XCTUnwrap(ChatBase64.decode(str(m, "iv"))))
            XCTAssertEqual(made.iv, str(m, "iv"), name)
            XCTAssertEqual(made.ct, str(m, "ct"), name)
            // what is signed, and both signatures verified (the vector's, and the one made here), never compared
            let signed = ChatCrypto.signedPart(room: room, epoch: epoch, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv"), ct: str(m, "ct"))
            XCTAssertEqual(String(data: signed, encoding: .utf8), str(m, "signed_string"), name)
            XCTAssertTrue(ChatCrypto.verify(signPublic: sender.signPublic, sig: str(m, "sig"), signed: signed), name)
            XCTAssertTrue(ChatCrypto.verify(signPublic: sender.signPublic, sig: made.sig, signed: signed), name)
            // and it opens
            let body = try ChatCrypto.open(room: room, epoch: epoch, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv"), ct: str(m, "ct"), sig: str(m, "sig"), key: roomKey(epoch), signPublic: sender.signPublic)
            XCTAssertEqual(body["t"] as? String, text, name)
        }
    }

    func testTheMessageFromThePageItselfIsAccepted() throws {
        let alice = try device("alice")
        let m = dict(dict(v["page_made"])["message_alice_epoch0"])
        let body = try ChatCrypto.open(room: room, epoch: 0, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv"), ct: str(m, "ct"), sig: str(m, "sig"), key: roomKey(0), signPublic: alice.signPublic)
        XCTAssertEqual(body["t"] as? String, "Made by the page's own code, random IV and signature.")
    }

    func testAChangedMessageOrAnotherSenderIsNotAccepted() throws {
        let alice = try device("alice"), bob = try device("bob")
        let m = dict(dict(v["page_made"])["message_alice_epoch0"])
        let key = try roomKey(0)
        XCTAssertThrowsError(try ChatCrypto.open(room: room, epoch: 0, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv"), ct: str(m, "ct"), sig: str(m, "sig"), key: key, signPublic: bob.signPublic)) {
            XCTAssertEqual($0 as? ChatCryptoError, .notVerified)
        }
        XCTAssertThrowsError(try ChatCrypto.open(room: room, epoch: 1, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv"), ct: str(m, "ct"), sig: str(m, "sig"), key: key, signPublic: alice.signPublic))
    }

    func testLiveAndNotesBoxesOpenWithTheirAads() throws {
        let live = dict(v["live"])
        let l = try ChatCrypto.openSealed(iv: str(live, "iv"), ct: str(live, "ct"), key: roomKey(0), aad: str(live, "aad"))
        XCTAssertEqual(l["d"] as? String, "Hello Bo")
        let box = dict(v["box"])
        let b = try ChatCrypto.openSealed(iv: str(box, "iv"), ct: str(box, "ct"), key: roomKey(0), aad: str(box, "aad"))
        XCTAssertEqual(b["text"] as? String, "Invented room note.")
        XCTAssertThrowsError(try ChatCrypto.openSealed(iv: str(live, "iv"), ct: str(live, "ct"), key: roomKey(0), aad: "\(room)|0|fingus|other"))
    }

    // MARK: the safety code

    func testSafetyCodesAreTheReferenceOnes() throws {
        let codes = dict(v["safety_codes"])
        for name in ["alice_one_device", "two_devices_sorted"] {
            let entry = dict(codes[name])
            let list = ((entry["devices"] as? [[String: Any]]) ?? []).map { (ecdh: str($0, "ecdh"), sign: str($0, "sign")) }
            XCTAssertEqual(ChatCrypto.safetyCode(list), str(entry, "code"), name)
        }
        // the order devices are given in does not matter
        let two = ((dict(codes["two_devices_sorted"])["devices"] as? [[String: Any]]) ?? []).map { (ecdh: str($0, "ecdh"), sign: str($0, "sign")) }
        XCTAssertEqual(ChatCrypto.safetyCode(two.reversed()), ChatCrypto.safetyCode(two))
        XCTAssertEqual(ChatCrypto.safetyCode([]), "")
    }

    func testAChangedCodeIsFlaggedUntilItIsAccepted() throws {
        let suite = "chat-safety-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let ledger = ChatSafetyLedger(defaults: defaults)
        let alice = try device("alice"), bob = try device("bob")
        func info(_ d: ChatDevice) -> ChatDeviceInfo { ChatDeviceInfo(device: d.id, ecdh: d.ecdhPublic, sign: d.signPublic) }
        XCTAssertEqual(ledger.rows(account: "me", devices: ["sam": [info(bob)]]).map(\.changed), [false])
        XCTAssertEqual(ledger.rows(account: "me", devices: ["sam": [info(bob)]]).map(\.changed), [false])
        let changed = ledger.rows(account: "me", devices: ["sam": [info(alice)]])
        XCTAssertEqual(changed.map(\.changed), [true])
        ledger.accept(account: "me", name: "sam", code: changed[0].code)
        XCTAssertEqual(ledger.rows(account: "me", devices: ["sam": [info(alice)]]).map(\.changed), [false])
    }

    // MARK: spelling

    func testOnlyTheStoresSpellingOfBase64IsAccepted() {
        XCTAssertNotNil(ChatBase64.decode("V-DoL6UtUHkWXIqK"))
        XCTAssertNil(ChatBase64.decode("V-DoL6UtUHkWXIqK="), "padding")
        XCTAssertNil(ChatBase64.decode("ab+/"), "standard alphabet")
        XCTAssertNil(ChatBase64.decode("A"), "length no encoder makes")
        XCTAssertNil(ChatBase64.decode("AB"), "trailing bits not zero")
        XCTAssertNil(ChatBase64.decode("ab cd"))
    }

    func testAnIvOrCiphertextInTheWrongSpellingIsRefused() throws {
        let m = dict(dict(v["page_made"])["message_alice_epoch0"])
        let alice = try device("alice")
        XCTAssertThrowsError(try ChatCrypto.open(room: room, epoch: 0, sender: str(m, "sender_id"), device: str(m, "device"), iv: str(m, "iv") + "=", ct: str(m, "ct"), sig: str(m, "sig"), key: roomKey(0), signPublic: alice.signPublic)) {
            XCTAssertEqual($0 as? ChatCryptoError, .badEncoding)
        }
    }

    func testJSONIsWrittenAsJSONStringifyWritesIt() {
        XCTAssertEqual(String(data: ChatCrypto.plaintext(text: "back/slash \"q\" \\ \n\u{1F}é"), encoding: .utf8), "{\"t\":\"back/slash \\\"q\\\" \\\\ \\n\\u001fé\"}")
    }

    // MARK: keeping the device

    private final class FailingStore: ChatKeyStore {
        var saved = 0
        var loadError: Error?
        var data: Data?
        func load(person: String) throws -> Data? { if let loadError { throw loadError }; return data }
        func save(_ data: Data, person: String) throws { saved += 1 }
    }

    func testAFailedReadNeverMakesANewDevice() {
        let store = FailingStore()
        store.loadError = ChatKeyError.unreadable(-25308)
        XCTAssertThrowsError(try ChatDeviceKeeper.device(for: "p1", in: store))
        XCTAssertEqual(store.saved, 0)
    }

    func testAKeptDeviceThatCannotBeReadIsNotReplaced() {
        let store = FailingStore()
        store.data = Data("not a device".utf8)
        XCTAssertThrowsError(try ChatDeviceKeeper.device(for: "p1", in: store)) { XCTAssertEqual($0 as? ChatKeyError, .corrupt) }
        XCTAssertEqual(store.saved, 0)
    }

    func testTheDeviceIsMadeOnlyWhenNothingIsKeptAndComesBackTheSame() throws {
        let store = MemoryChatKeyStore()
        let first = try ChatDeviceKeeper.device(for: "p1", in: store)
        let again = try ChatDeviceKeeper.device(for: "p1", in: store)
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(first.ecdhPublic, again.ecdhPublic)
        XCTAssertEqual(first.signPublic, again.signPublic)
        XCTAssertNotEqual(try ChatDeviceKeeper.device(for: "p2", in: store).id, first.id)
    }

    // MARK: cookies, the account and Locked

    func testOnlyTheCookiesThatApplyToTheAddressAreKept() throws {
        func cookie(_ domain: String, _ path: String, secure: Bool = true) throws -> HTTPCookie {
            var p: [HTTPCookiePropertyKey: Any] = [.name: "n", .value: "v", .domain: domain, .path: path]
            if secure { p[.secure] = "TRUE" }
            return try XCTUnwrap(HTTPCookie(properties: p))
        }
        let url = URL(string: "https://aero.example.ts.net/aero/")!
        let kept = ChatAPI.applicable([try cookie("aero.example.ts.net", "/"), try cookie(".example.ts.net", "/aero"), try cookie("other.example.com", "/"),
                                       try cookie("aero.example.ts.net", "/elsewhere")], to: url)
        XCTAssertEqual(kept.map(\.domain), ["aero.example.ts.net", ".example.ts.net"])
        XCTAssertTrue(ChatAPI.applicable([try cookie("aero.example.ts.net", "/")], to: URL(string: "http://aero.example.ts.net/aero/")!).isEmpty)
    }

    @MainActor
    func testAnAccountChangeClearsTheKeysAndTellsTheScreens() {
        let session = ChatSession(api: ChatAPI(), keyStore: MemoryChatKeyStore())
        session.keep(ChatCrypto.freshKey(), room: "rabc", epoch: 0)
        var told = 0
        session.onReset = { told += 1 }
        let before = session.generation
        session.reset()
        XCTAssertFalse(session.hasAnyKey(room: "rabc"))
        XCTAssertEqual(session.generation, before + 1)
        XCTAssertEqual(told, 1)
    }

    @MainActor
    func testLockedClosingClearsTheChatAndNeverPutsTheDraftBack() {
        let session = ChatSession(api: ChatAPI(), keyStore: MemoryChatKeyStore())
        session.keep(ChatCrypto.freshKey(), room: "rlocked", epoch: 0)
        let model = ChatRoomModel(session: session, room: ChatRoomRow(id: "rlocked", name: "Plans", isLocked: true), privacy: .open)
        XCTAssertEqual(model.privacy, .locked)
        XCTAssertEqual(model.title, "Plans")
        model.draft = "something private"
        model.shut()
        XCTAssertEqual(model.draft, "")
        XCTAssertTrue(model.lines.isEmpty)
        XCTAssertEqual(model.phase, .locked)
        XCTAssertEqual(model.title, ChatWords.lockedTitle)
        XCTAssertFalse(session.hasAnyKey(room: "rlocked"))
    }
}
