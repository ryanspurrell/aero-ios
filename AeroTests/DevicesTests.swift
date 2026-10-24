import XCTest
import CryptoKit
@testable import Aero

/// What a request body was, for a stub (a URLProtocol sees the body as a stream).
extension URLRequest {
    var bodyBytes: Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }
}

/// Holds what a stub saw, safely across the thread a URLProtocol answers on.
final class StubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bodies: [String: [Data]] = [:]
    private var values: [String: String] = [:]
    func add(_ key: String, _ body: Data) { lock.lock(); bodies[key, default: []].append(body); lock.unlock() }
    func all(_ key: String) -> [Data] { lock.lock(); defer { lock.unlock() }; return bodies[key] ?? [] }
    func json(_ key: String) -> [String: Any]? { all(key).last.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    func set(_ key: String, _ value: String) { lock.lock(); values[key] = value; lock.unlock() }
    func get(_ key: String) -> String { lock.lock(); defer { lock.unlock() }; return values[key] ?? "" }
}

/// The vectors file and the approving device it names (invented keys).
enum DeviceVectors {
    static func load() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: DeviceSigningTests.self).url(forResource: "vectors", withExtension: "json", subdirectory: "Fixtures/device_signing"), "the vectors are not in the test bundle")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func hex(_ text: String) -> Data {
        var out = Data(); var i = text.startIndex
        while i < text.endIndex { let j = text.index(i, offsetBy: 2); out.append(UInt8(text[i..<j], radix: 16)!); i = j }
        return out
    }

    /// The approving device of the vectors, with its invented keys.
    static func approver() throws -> ChatDevice {
        let v = try load()
        let s = try P256.Signing.PrivateKey(rawRepresentation: hex((v["approver_sign_private_scalar_hex"] as? String) ?? ""))
        let made = ChatDevice.software(person: (v["person"] as? String) ?? "", id: (v["approver_device"] as? String) ?? "", ecdh: P256.KeyAgreement.PrivateKey(), sign: s)
        XCTAssertEqual(made.signPublic, v["approver_sign_public"] as? String)
        return made
    }
}

/// Signing for device approval, against what the Messages store itself says (Fixtures/device_signing/vectors.json, made by
/// tools/device_signing_vectors.py from the store's own `approval_text`, `removal_text` and `verify`; the store also accepted these proofs).
final class DeviceSigningTests: XCTestCase {
    private var v: [String: Any] = [:]

    override func setUpWithError() throws {
        v = try DeviceVectors.load()
    }

    private func str(_ key: String) -> String { (v[key] as? String) ?? "" }
    private var target: [String: Any] { (v["target"] as? [String: Any]) ?? [:] }

    func testTheApprovalAndRemovalTextsAreTheStoresOwn() {
        let ts = (v["ts"] as? Int) ?? 0
        XCTAssertEqual(DeviceSigning.approvalText(person: str("person"), device: target["device"] as? String ?? "", ecdh: target["ecdh"] as? String ?? "",
                                                  sign: target["sign"] as? String ?? "", ts: ts), str("approval_text"))
        XCTAssertEqual(DeviceSigning.removalText(person: str("person"), device: target["device"] as? String ?? "", ts: ts), str("removal_text"))
    }

    func testTheProofsTheStoreAcceptedAreAcceptedHere() {
        XCTAssertTrue(ChatCrypto.verify(signPublic: str("approver_sign_public"), sig: str("approval_proof"), signed: Data(str("approval_text").utf8)))
        XCTAssertTrue(ChatCrypto.verify(signPublic: str("approver_sign_public"), sig: str("removal_proof"), signed: Data(str("removal_text").utf8)))
        // an approval is not a removal, and a changed text is not the one signed
        XCTAssertFalse(ChatCrypto.verify(signPublic: str("approver_sign_public"), sig: str("approval_proof"), signed: Data(str("removal_text").utf8)))
        XCTAssertFalse(ChatCrypto.verify(signPublic: str("approver_sign_public"), sig: str("approval_proof"), signed: Data((str("approval_text") + "x").utf8)))
    }

    func testAProofMadeHereIsInTheStoresFormatAndChecksWithThePublicKey() throws {
        let device = try DeviceVectors.approver()
        for text in [str("approval_text"), str("removal_text")] {
            let proof = try DeviceSigning.proof(text, by: device)
            // base64url, no padding, 64 bytes (r then s)
            XCTAssertFalse(proof.contains("=") || proof.contains("+") || proof.contains("/"), proof)
            XCTAssertEqual(ChatBase64.decode(proof)?.count, 64)
            XCTAssertTrue(ChatCrypto.verify(signPublic: device.signPublic, sig: proof, signed: Data(text.utf8)))
            XCTAssertFalse(ChatCrypto.verify(signPublic: device.signPublic, sig: proof, signed: Data((text + "x").utf8)))
        }
    }
}

/// The Devices screen's model against a stand-in for Aero (LiveStub) that answers with the store's own list (Fixtures/device_signing).
@MainActor
final class DevicesModelTests: XCTestCase {
    private var saved: URL?
    private let box = StubBox()

    override func setUp() {
        super.setUp()
        saved = AppInfo.address
        AppInfo.address = URL(string: "https://aero.invalid")
        LiveStub.reset()
        ConnectionMonitor.shared.startAgain()
    }

    override func tearDown() {
        AppInfo.address = saved
        LiveStub.reset()
        super.tearDown()
    }

    /// A session whose device is the vectors' approving device (so the list the store made names it), served by a stub that answers the list
    /// with the given trust for this phone, and records every body it is sent.
    private func makeSession(thisTrusted: Bool = true, otherTrusted: Bool = false) throws -> (ChatSession, [String: Any]) {
        let alice = try DeviceVectors.approver()
        let store = MemoryChatKeyStore()
        try store.save(try alice.kept(), person: alice.person)
        var mine = try XCTUnwrap(try DeviceVectors.load()["devices_mine"] as? [String: Any])
        var rows = try XCTUnwrap(mine["devices"] as? [[String: Any]])
        rows[0]["trusted"] = thisTrusted
        rows[1]["trusted"] = otherTrusted
        mine["devices"] = rows
        let list = try JSONSerialization.data(withJSONObject: mine)
        let person = alice.person
        LiveStub.json("GET /rooms.json", #"{"me":"owner","me_id":"\#(person)","owner":"Aryn","rooms":[]}"#)
        LiveStub.route("POST /devices") { r in
            self.box.add("register", r.bodyBytes)
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"trusted":\#(thisTrusted),"name":"Mango"}"#.utf8))
        }
        LiveStub.route("GET /devices/mine.json") { _ in LiveStub.Answer(status: 200, body: list) }
        for path in ["approve", "remove", "rename"] {
            LiveStub.route("POST /devices/\(path)") { r in
                self.box.add(path, r.bodyBytes)
                return LiveStub.Answer(status: 200, body: Data(path == "rename" ? #"{"ok":true,"name":"Fig"}"#.utf8 : #"{"ok":true,"changed":true}"#.utf8))
            }
        }
        return (ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: store), rows[1])
    }

    // MARK: what the screen holds

    func testTheListIsReadAndAWaitingDeviceComesFirst() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        XCTAssertNil(model.stopped)
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertTrue(model.iAmTrusted)
        XCTAssertEqual(model.ordered.map(\.trusted), [false, true])
        XCTAssertNil(model.thisPhoneWaiting)
    }

    func testAPhoneThatIsWaitingKnowsItAndCannotApproveOrRemove() async throws {
        let (session, other) = try makeSession(thisTrusted: false, otherTrusted: false)
        let model = DevicesModel(session: session)
        await model.load()
        XCTAssertFalse(model.iAmTrusted)
        XCTAssertEqual(model.thisPhoneWaiting?.name, "Mango")
        let row = try JSONDecoder().decode(DeviceRow.self, from: JSONSerialization.data(withJSONObject: other))
        await model.approve(row)
        await model.removeTapped(row)
        await model.removeTapped(row)
        XCTAssertTrue(box.all("approve").isEmpty)
        XCTAssertTrue(box.all("remove").isEmpty)
        XCTAssertEqual(DeviceListing.removalBlocked(row, rows: model.rows, this: model.thisDevice), DevicesWords.removeNeedsApproval)
    }

    // MARK: approving

    func testApprovingSignsTheNewDevicesKeysAndSendsTheProof() async throws {
        let (session, other) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let row = try JSONDecoder().decode(DeviceRow.self, from: JSONSerialization.data(withJSONObject: other))
        XCTAssertTrue(DeviceListing.canApprove(row, rows: model.rows, this: model.thisDevice))
        await model.approve(row)
        XCTAssertNil(model.stopped)
        XCTAssertEqual(model.notice, DevicesWords.approved)
        let sent = try XCTUnwrap(box.json("approve"))
        let alice = try DeviceVectors.approver()
        XCTAssertEqual(sent["by"] as? String, alice.id)
        XCTAssertEqual(sent["device"] as? String, row.device)
        // the time is Aero's clock (the list's `now`, 1700000000) carried forward by the time since it was read
        let ts = try XCTUnwrap(sent["ts"] as? Int)
        XCTAssertTrue((1_700_000_000...1_700_000_030).contains(ts), "\(ts)")
        let proof = try XCTUnwrap(sent["proof"] as? String)
        let text = DeviceSigning.approvalText(person: alice.person, device: row.device, ecdh: row.ecdh, sign: row.sign, ts: ts)
        XCTAssertTrue(ChatCrypto.verify(signPublic: alice.signPublic, sig: proof, signed: Data(text.utf8)))
        // the proof is for this device's keys and this time only
        XCTAssertFalse(ChatCrypto.verify(signPublic: alice.signPublic, sig: proof, signed: Data(DeviceSigning.approvalText(person: alice.person, device: row.device, ecdh: row.ecdh, sign: row.sign, ts: ts + 1).utf8)))
    }

    func testARefusalIsSaidInTheOneShape() async throws {
        let (session, other) = try makeSession()
        LiveStub.route("POST /devices/approve") { _ in LiveStub.Answer(status: 400, body: Data(#"{"error":"that did not check"}"#.utf8)) }
        let model = DevicesModel(session: session)
        await model.load()
        await model.approve(try JSONDecoder().decode(DeviceRow.self, from: JSONSerialization.data(withJSONObject: other)))
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains(DevicesWords.approving), said)
        XCTAssertTrue(said.contains("that did not check"), said)
    }

    // MARK: removing

    func testRemovingAsksTwiceAndSignsTheRemoval() async throws {
        let (session, other) = try makeSession(otherTrusted: true)
        let model = DevicesModel(session: session)
        await model.load()
        let row = try JSONDecoder().decode(DeviceRow.self, from: JSONSerialization.data(withJSONObject: other))
        await model.removeTapped(row)
        XCTAssertEqual(model.armed, row.device)
        XCTAssertTrue(box.all("remove").isEmpty, "the first tap only asks")
        await model.removeTapped(row)
        XCTAssertNil(model.armed)
        let sent = try XCTUnwrap(box.json("remove"))
        let alice = try DeviceVectors.approver()
        let ts = try XCTUnwrap(sent["ts"] as? Int)
        XCTAssertEqual(sent["device"] as? String, row.device)
        XCTAssertTrue(ChatCrypto.verify(signPublic: alice.signPublic, sig: try XCTUnwrap(sent["proof"] as? String),
                                        signed: Data(DeviceSigning.removalText(person: alice.person, device: row.device, ts: ts).utf8)))
    }

    func testWhichDevicesMayBeRemovedFromThisPhone() {
        func row(_ id: String, trusted: Bool) -> DeviceRow { DeviceRow(device: id, name: id, kind: nil, added: 1, trusted: trusted, approvedBy: nil, ecdh: "e", sign: "s") }
        let me = row("me", trusted: true), waiting = row("w", trusted: false), other = row("o", trusted: true)
        // this phone is approved: it may remove the others, but not itself (its chats would lose their keys under it)
        XCTAssertNil(DeviceListing.removalBlocked(waiting, rows: [me, waiting], this: "me"))
        XCTAssertNil(DeviceListing.removalBlocked(other, rows: [me, other], this: "me"))
        XCTAssertEqual(DeviceListing.removalBlocked(me, rows: [me, other], this: "me"), DevicesWords.removeFromAnother)
        // this phone is waiting: it cannot remove anything until it is approved
        let meWaiting = row("me", trusted: false)
        XCTAssertEqual(DeviceListing.removalBlocked(other, rows: [meWaiting, other], this: "me"), DevicesWords.removeNeedsApproval)
        // before this phone is known at all, nothing is offered
        XCTAssertEqual(DeviceListing.removalBlocked(other, rows: [other], this: nil), DevicesWords.removeNeedsApproval)
    }

    func testOnlyAnApprovedPhoneApprovesAndNeverItself() {
        func row(_ id: String, trusted: Bool) -> DeviceRow { DeviceRow(device: id, name: id, kind: nil, added: 1, trusted: trusted, approvedBy: nil, ecdh: "e", sign: "s") }
        let me = row("me", trusted: true), waiting = row("w", trusted: false), meWaiting = row("me", trusted: false)
        XCTAssertTrue(DeviceListing.canApprove(waiting, rows: [me, waiting], this: "me"))
        XCTAssertFalse(DeviceListing.canApprove(me, rows: [me, waiting], this: "me"), "an approved device has nothing to approve")
        XCTAssertFalse(DeviceListing.canApprove(waiting, rows: [meWaiting, waiting], this: "me"), "a waiting phone approves nothing")
        XCTAssertFalse(DeviceListing.canApprove(meWaiting, rows: [meWaiting], this: "me"), "and not itself")
    }

    // MARK: renaming

    func testRenamingSendsOnlyTheNameAndReadsTheListAgain() async throws {
        let (session, other) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let row = try JSONDecoder().decode(DeviceRow.self, from: JSONSerialization.data(withJSONObject: other))
        await model.rename(row, to: "  Fig   tree ")
        let sent = try XCTUnwrap(box.json("rename"))
        XCTAssertEqual(sent["device"] as? String, row.device)
        XCTAssertEqual(sent["name"] as? String, "Fig tree")
        XCTAssertEqual(Set(sent.keys), ["device", "name"])
        XCTAssertEqual(model.notice, DevicesWords.renamed)
        // a name that is empty, or the one it has, asks nothing
        await model.rename(row, to: "   ")
        XCTAssertEqual(box.all("rename").count, 1)
    }

    // MARK: the words

    func testWhatARowSaysAndInWhatOrder() {
        let waiting = DeviceRow(device: "w", name: "Coconut", kind: "Safari on iPhone", added: 5, trusted: false, approvedBy: nil, ecdh: "e", sign: "s")
        let kept = DeviceRow(device: "k", name: "Kiwi", kind: "This PC", added: 1_700_000_000, trusted: true, approvedBy: "machine", ecdh: "e", sign: "s")
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(DeviceListing.note(waiting, calendar: utc, locale: en), "Waiting for approval")
        XCTAssertEqual(DeviceListing.note(kept, calendar: utc, locale: en), "This PC \u{00B7} Added Nov 14, 2023")
        XCTAssertEqual(DeviceListing.title(kept, this: "k"), "Kiwi (this phone)")
        XCTAssertEqual(DeviceListing.title(waiting, this: "k"), "Coconut")
        XCTAssertEqual(DeviceListing.order([kept, waiting]).map(\.device), ["w", "k"])
        XCTAssertEqual(DeviceRow(device: "n", name: nil, kind: nil, added: nil, trusted: true, approvedBy: nil, ecdh: "", sign: "").shownName, "A device")
    }

    func testTheListTheStoreMadeDecodes() throws {
        let mine = try XCTUnwrap(try DeviceVectors.load()["devices_mine"])
        let answer = try JSONDecoder().decode(DevicesAnswer.self, from: JSONSerialization.data(withJSONObject: mine))
        XCTAssertEqual(answer.now, 1_700_000_000)
        XCTAssertEqual(answer.devices.map(\.trusted), [true, false])
        XCTAssertEqual(answer.devices.first?.kind, "iPhone (Aero app)")
    }

    // MARK: this phone while it waits

    func testAPhoneWaitingForApprovalIsToldItsNameAndWhereToApprove() async throws {
        let (session, _) = try makeSession(thisTrusted: false)
        let list = ChatListModel(session: session)
        await list.load()
        let waiting = try XCTUnwrap(list.waiting)
        XCTAssertEqual(waiting.name, "Mango")
        let words = ChatWords.waitingNote(waiting.name)
        XCTAssertTrue(words.contains("Mango"), words)
        XCTAssertTrue(words.contains("You") && words.contains("Devices") && words.contains("Approve"), words)
        XCTAssertEqual(ChatWords.waitingTitle, "Waiting for approval")
    }

    func testAnApprovedPhoneIsNotToldToWait() async throws {
        let (session, _) = try makeSession(thisTrusted: true)
        let list = ChatListModel(session: session)
        await list.load()
        XCTAssertNil(list.waiting)
    }

    func testAWaitingPhoneCannotSendAndSaysWhy() async throws {
        let (session, _) = try makeSession(thisTrusted: false)
        LiveStub.route("GET /private/unlock/status") { _ in LiveStub.Answer(status: 200, body: Data(#"{"unlocked":false}"#.utf8)) }
        LiveStub.json("GET /rooms/people.json", #"{"models":["llama-demo:8b"]}"#)
        let model = ChatRoomModel(session: session, room: nil, privacy: .open)
        await model.load()
        model.draft = "hello"
        await model.send()
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains("Mango") && said.contains("approved"), said)
        XCTAssertFalse(LiveStub.seen.contains("POST /rooms/new"))
        XCTAssertEqual(model.draft, "hello", "the words stay in the box")
    }

    func testAnOlderAeroThatSaysNothingOfApprovalIsTreatedAsApproved() {
        XCTAssertTrue(ChatRegistration.read(Data(#"{"ok": true}"#.utf8)).trusted)
        XCTAssertTrue(ChatRegistration.read(Data()).trusted)
        XCTAssertEqual(ChatRegistration.read(Data(#"{"ok":true,"trusted":false,"name":"Papaya"}"#.utf8)), ChatRegistration(trusted: false, name: "Papaya"))
    }
}
