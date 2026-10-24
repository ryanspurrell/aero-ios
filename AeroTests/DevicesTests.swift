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

/// The unified list as the PC makes it (aero_devices_one.view over invented parts, run by hand once): a device in use, one under removal that
/// stopped, a waiting chat key with its code, a sign-in that was stopped at the door.
private let pcListing = #"""
{"devices": [{"id": "t1", "name": "Coconut", "kind": "iPhone", "this": true, "parts": {"session": [{"id": "s1", "label": "Aero", "agent": "Aero app", "seen": 1700000000, "settings": {}, "cut": {"at": 1700000100, "by": "x"}}], "chat": [{"device": "cd1", "name": "Coconut", "label": "iPhone (Aero app)", "added": 1.0, "trusted": true, "approved_by": "machine", "ecdh": "A", "sign": "B"}], "key": [{"device": "k1", "label": "phone", "kind": "web", "added": 3, "used": 1700000050, "via": null, "agent": null}]}, "waiting": false, "seen": 1700000050, "confirmed": 1700000200, "can_remove": false, "why_not": "You are using it now", "info": {"seen": 1700000050, "confirmed": true}, "confirm_first": []}, {"id": "t2", "name": "Sapodilla", "kind": "iPhone", "removing": {"since": 1, "done": ["messages"], "stuck": {"step": "coreKey", "why": "Couldn't reach Core"}}, "this": false, "parts": {"session": [{"id": "s2", "label": "Safari on iPhone", "agent": "Safari on iPhone", "seen": 1700000000, "settings": {}}], "chat": [{"device": "cd2", "name": "Sapodilla", "label": "x", "added": 2.0, "trusted": false, "approved_by": null, "ecdh": "A", "sign": "B", "code": "610778", "code_shown": "610 778"}], "key": []}, "waiting": true, "seen": 1700000000, "can_remove": false, "why_not": "Removing", "info": {"seen": 1700000000, "confirmed": false}, "confirm_first": []}], "maybe_same": [{"a": "t1", "b": "t2", "why": "Coconut and Sapodilla used the same browser to sign in and to set up chats"}], "ok": true, "now": 1700000200}
"""#

/// The Devices screen's model against a stand-in for the PC (LiveStub) that answers the unified list, with the keys of the store's own vectors
/// (Fixtures/device_signing): this phone is the vectors' approving device.
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

    /// One device row as the PC lists it, for the given chat key.
    private func listed(_ id: String, name: String, this: Bool, key: [String: Any], trusted: Bool, canRemove: Bool = true, whyNot: String = "",
                        seen: Int = 1_600_000_000, confirmed: Bool = true, confirmFirst: [String] = [], removing: [String: Any]? = nil) -> [String: Any] {
        var chat: [String: Any] = ["device": key["device"] ?? "", "name": name, "label": key["kind"] ?? "", "added": key["added"] ?? 0, "trusted": trusted,
                                   "approved_by": trusted ? "machine" : NSNull(), "ecdh": key["ecdh"] ?? "", "sign": key["sign"] ?? ""]
        if !trusted {
            let code = DeviceCode.code(ecdh: key["ecdh"] as? String ?? "", sign: key["sign"] as? String ?? "")
            chat["code"] = code
            chat["code_shown"] = DeviceCode.shown(code)
        }
        var row: [String: Any] = ["id": id, "name": name, "kind": "iPhone", "this": this, "waiting": !trusted, "seen": seen, "can_remove": canRemove,
                                  "why_not": whyNot, "info": ["seen": seen, "confirmed": confirmed], "confirm_first": confirmFirst,
                                  "parts": ["session": [], "chat": [chat], "key": []]]
        if let removing { row["removing"] = removing }
        return row
    }

    /// A session whose device is the vectors' approving device, served by a stub that lists it and one other device and records every body.
    private func makeSession(thisTrusted: Bool = true, otherTrusted: Bool = false, canRemove: Bool = true, confirmFirst: [String] = [],
                             otherRemoving: [String: Any]? = nil) throws -> (ChatSession, [String: Any]) {
        let alice = try DeviceVectors.approver()
        let store = MemoryChatKeyStore()
        try store.save(try alice.kept(), person: alice.person)
        let mine = try XCTUnwrap(try DeviceVectors.load()["devices_mine"] as? [String: Any])
        let keys = try XCTUnwrap(mine["devices"] as? [[String: Any]])
        let rows = [listed("t-me", name: "Mango", this: true, key: keys[0], trusted: thisTrusted, canRemove: false, whyNot: "You are using it now"),
                    listed("t-other", name: "Fig", this: false, key: keys[1], trusted: otherTrusted, canRemove: canRemove, seen: 1_700_000_000,
                           confirmed: confirmFirst.isEmpty, confirmFirst: confirmFirst, removing: otherRemoving)]
        let list = try JSONSerialization.data(withJSONObject: ["ok": true, "now": 1_700_000_000, "devices": rows, "maybe_same": []] as [String: Any])
        var old = mine
        var oldRows = keys
        oldRows[0]["trusted"] = thisTrusted
        oldRows[1]["trusted"] = otherTrusted
        old["devices"] = oldRows
        let oldList = try JSONSerialization.data(withJSONObject: old)
        let person = alice.person
        LiveStub.json("GET /rooms.json", #"{"me":"owner","me_id":"\#(person)","owner":"Aryn","rooms":[]}"#)
        LiveStub.route("POST /devices") { r in
            self.box.add("register", r.bodyBytes)
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"trusted":\#(thisTrusted),"name":"Mango"}"#.utf8))
        }
        LiveStub.route("GET /devices/mine.json") { _ in LiveStub.Answer(status: 200, body: oldList) }
        LiveStub.route("GET /one-devices.json") { r in
            self.box.set("chat", URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "chat" }?.value ?? "")
            return LiveStub.Answer(status: 200, body: list)
        }
        for path in ["approve", "remove"] {
            LiveStub.route("POST /devices/\(path)") { r in
                self.box.add(path, r.bodyBytes)
                return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"changed":true}"#.utf8))
            }
        }
        LiveStub.route("POST /one-devices/rename") { r in
            self.box.add("rename", r.bodyBytes)
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"name":"Pear"}"#.utf8))
        }
        LiveStub.route("POST /one-devices/merge") { r in
            self.box.add("merge", r.bodyBytes)
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"name":"Mango"}"#.utf8))
        }
        return (ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: store), rows[1])
    }

    private func other(_ model: DevicesModel) throws -> OneDevice { try XCTUnwrap(model.device("t-other")) }

    /// The PC's answers to `one-devices/remove`, in order; each is (status, body). The bodies it was sent are in the box under "oneRemove".
    private func removalAnswers(_ answers: [(Int, String)]) {
        let next = StubBox()
        LiveStub.route("POST /one-devices/remove") { r in
            self.box.add("oneRemove", r.bodyBytes)
            let n = next.all("n").count
            next.add("n", Data())
            let (status, body) = answers[min(n, answers.count - 1)]
            return LiveStub.Answer(status: status, body: Data(body.utf8))
        }
    }

    // MARK: what the screen holds

    func testTheListIsReadWithThisPhonesOwnChatKeyAndEachDeviceIsOneRow() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        XCTAssertNil(model.stopped)
        XCTAssertEqual(model.devices.map(\.id), ["t-me", "t-other"])
        XCTAssertTrue(model.iAmTrusted)
        XCTAssertNil(model.thisPhoneWaiting)
        XCTAssertEqual(box.get("chat"), try DeviceVectors.approver().id, "the PC is told which chat key is this phone's, so it marks the row")
        XCTAssertEqual(try other(model).parts.chat.count, 1)
    }

    func testTheListThePCMakesDecodesWithAllItsPartsAndTheRemovalJournal() throws {
        let got = try JSONDecoder().decode(OneDevicesAnswer.self, from: Data(pcListing.utf8))
        XCTAssertEqual(got.now, 1_700_000_200)
        let me = got.devices[0], gone = got.devices[1]
        XCTAssertTrue(me.this)
        XCTAssertEqual(me.parts.session.count, 1)
        XCTAssertTrue(me.parts.session[0].cut)
        XCTAssertEqual(me.parts.chat[0].approvedBy, "machine")
        XCTAssertEqual(me.parts.key[0].used, 1_700_000_050)
        XCTAssertEqual(me.info, OneInfo(seen: 1_700_000_050, confirmed: true))
        XCTAssertEqual(OneDeviceListing.has(me), "1 sign-in, 1 chat key, 1 file key")
        XCTAssertEqual(OneDeviceListing.note(me), "iPhone \u{00B7} Signed in \u{00B7} Chat keys \u{00B7} Files")
        XCTAssertEqual(gone.removing, OneRemoving(done: ["messages"], stuck: "Couldn't reach Core"))
        XCTAssertEqual(OneDeviceListing.note(gone), "Removing\u{2026} Couldn't reach Core")
        XCTAssertEqual(gone.parts.chat[0].code, "610778")
        XCTAssertEqual(OneDeviceListing.shownCode(gone.parts.chat[0]), "610 778", "the PC's code and the one made here are the same for these keys")
        XCTAssertEqual(got.maybeSame.first?.why, "Coconut and Sapodilla used the same browser to sign in and to set up chats")
    }

    func testAPhoneThatIsWaitingKnowsItAndCannotApproveOrRemove() async throws {
        let (session, _) = try makeSession(thisTrusted: false, otherTrusted: false)
        let model = DevicesModel(session: session)
        await model.load()
        XCTAssertFalse(model.iAmTrusted)
        XCTAssertNotNil(model.thisPhoneWaiting)
        let row = try other(model)
        await model.approve(row)
        await model.removeTapped(row)
        await model.removeTapped(row)
        XCTAssertTrue(box.all("approve").isEmpty)
        XCTAssertTrue(LiveStub.seen.filter { $0 == "POST /one-devices/remove" }.isEmpty)
        XCTAssertEqual(OneDeviceListing.removalBlocked(row, devices: model.devices, thisChat: model.thisDevice), DevicesWords.removeNeedsApproval)
    }

    // MARK: approving

    func testApprovingSignsTheWaitingKeysWithTheMatchingCodeAndSendsTheProof() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let row = try other(model)
        let key = row.parts.chat[0]
        XCTAssertEqual(OneDeviceListing.approvable(row, devices: model.devices, thisChat: model.thisDevice).map(\.device), [key.device])
        await model.approve(row)
        XCTAssertNil(model.stopped)
        XCTAssertEqual(model.notice, DevicesWords.approved)
        let sent = try XCTUnwrap(box.json("approve"))
        let alice = try DeviceVectors.approver()
        XCTAssertEqual(sent["by"] as? String, alice.id)
        XCTAssertEqual(sent["device"] as? String, key.device)
        XCTAssertEqual(sent["code"] as? String, DeviceCode.code(ecdh: key.ecdh, sign: key.sign), "the code she saw on both screens goes with it")
        // the time is the PC's clock (the list's `now`, 1700000000) carried forward by the time since it was read
        let ts = try XCTUnwrap(sent["ts"] as? Int)
        XCTAssertTrue((1_700_000_000...1_700_000_030).contains(ts), "\(ts)")
        let proof = try XCTUnwrap(sent["proof"] as? String)
        let text = DeviceSigning.approvalText(person: alice.person, device: key.device, ecdh: key.ecdh, sign: key.sign, ts: ts)
        XCTAssertTrue(ChatCrypto.verify(signPublic: alice.signPublic, sig: proof, signed: Data(text.utf8)))
        // the proof is for this device's keys and this time only
        XCTAssertFalse(ChatCrypto.verify(signPublic: alice.signPublic, sig: proof, signed: Data(DeviceSigning.approvalText(person: alice.person, device: key.device, ecdh: key.ecdh, sign: key.sign, ts: ts + 1).utf8)))
    }

    func testAKeyWhoseCodeThePCListsDifferentlyIsNotApproved() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        var row = try other(model)
        row.parts.chat[0].code = "000000"
        XCTAssertNil(OneDeviceListing.shownCode(row.parts.chat[0]))
        await model.approve(row)
        XCTAssertTrue(box.all("approve").isEmpty)
        XCTAssertTrue(try XCTUnwrap(model.stopped).text.contains(DevicesWords.codeNotThisDevices))
    }

    func testTheShownCodeOfTheTestKeysIs610778() {
        let k = OneChatKey(device: "d", trusted: false, ecdh: "A", sign: "B", code: "610778", codeShown: "610 778")
        XCTAssertEqual(OneDeviceListing.shownCode(k), "610 778")
        XCTAssertEqual(DeviceSigning.approvalText(person: "p", device: "d", ecdh: "A", sign: "B", ts: 5), "approve|p|d|A|B|5|610778")
    }

    func testARefusalIsSaidInTheOneShape() async throws {
        let (session, _) = try makeSession()
        LiveStub.route("POST /devices/approve") { _ in LiveStub.Answer(status: 400, body: Data(#"{"error":"that did not check"}"#.utf8)) }
        let model = DevicesModel(session: session)
        await model.load()
        await model.approve(try other(model))
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains(DevicesWords.approving), said)
        XCTAssertTrue(said.contains("that did not check"), said)
    }

    // MARK: removing

    func testRemovingAsksTwiceThenForgetsTheChatKeySignedAndTheRestGoesFromThePC() async throws {
        let (session, _) = try makeSession(otherTrusted: true)
        removalAnswers([(200, #"{"ok":true,"gone":false,"done":["messages"],"stuck":null,"keys":0,"sessions":1,"chat":1}"#),
                        (200, #"{"ok":true,"gone":true,"done":["messages","coreKey","sessions"],"stuck":null}"#)])
        let model = DevicesModel(session: session)
        await model.load()
        let row = try other(model)
        await model.removeTapped(row)
        XCTAssertEqual(model.armed, row.id)
        XCTAssertTrue(box.all("oneRemove").isEmpty, "the first tap only asks")
        await model.removeTapped(row)
        XCTAssertNil(model.armed)
        XCTAssertEqual(model.notice, DevicesWords.removed)
        XCTAssertEqual(box.all("oneRemove").count, 2)
        XCTAssertEqual(box.json("oneRemove")?["thing"] as? String, "t-other")
        XCTAssertNil(box.json("oneRemove")?["ack"])
        // the chat key was forgotten between the two, signed by this phone
        let sent = try XCTUnwrap(box.json("remove"))
        let alice = try DeviceVectors.approver()
        let ts = try XCTUnwrap(sent["ts"] as? Int)
        XCTAssertEqual(sent["device"] as? String, row.parts.chat[0].device)
        XCTAssertTrue(ChatCrypto.verify(signPublic: alice.signPublic, sig: try XCTUnwrap(sent["proof"] as? String),
                                        signed: Data(DeviceSigning.removalText(person: alice.person, device: row.parts.chat[0].device, ts: ts).utf8)))
        let order = LiveStub.seen.filter { $0.contains("remove") }
        XCTAssertEqual(order, ["POST /one-devices/remove", "POST /devices/remove", "POST /one-devices/remove"])
    }

    func testADeviceUsedLatelyIsNotRemovedUntilSheConfirmsItIsNotHersSeeingWhy() async throws {
        let reasons = ["It was in use 3 minutes ago", "You haven't used it to confirm it is yours"]
        let (session, _) = try makeSession(otherTrusted: true, confirmFirst: reasons)
        let confirmBody = #"{"ok":false,"error":"It was in use 3 minutes ago; You haven't used it to confirm it is yours","confirm":{"reasons":["It was in use 3 minutes ago","You haven't used it to confirm it is yours"],"info":{"seen":1700000000,"confirmed":false}}}"#
        removalAnswers([(409, confirmBody), (409, confirmBody), (200, #"{"ok":true,"gone":false,"done":["messages"],"stuck":null}"#),
                        (200, #"{"ok":true,"gone":true,"done":["messages","coreKey","sessions"],"stuck":null}"#)])
        let model = DevicesModel(session: session)
        await model.load()
        let row = try other(model)
        XCTAssertEqual(row.confirmFirst, reasons)
        await model.removeTapped(row)
        await model.removeTapped(row)
        // she is asked, with the reasons and the evidence; nothing was forgotten and nothing is said to have failed
        let ask = try XCTUnwrap(model.asking)
        XCTAssertEqual(ask.reasons, reasons)
        XCTAssertEqual(ask.info, OneInfo(seen: 1_700_000_000, confirmed: false))
        XCTAssertNil(model.stopped)
        XCTAssertTrue(box.all("remove").isEmpty)
        XCTAssertEqual(box.all("oneRemove").count, 1)
        // "Keep it" leaves everything as it was
        model.leaveAsk()
        XCTAssertNil(model.asking)
        XCTAssertEqual(box.all("oneRemove").count, 1)
        await model.removeTapped(row)
        await model.removeTapped(row)
        XCTAssertNotNil(model.asking)
        await model.confirmNotYours()
        // the evidence goes back exactly as shown
        let ack = try XCTUnwrap(box.all("oneRemove").compactMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["ack"] as? [String: Any] }.first)
        XCTAssertEqual(ack["seen"] as? Int, 1_700_000_000)
        XCTAssertEqual(ack["confirmed"] as? Bool, false)
        XCTAssertNil(model.asking)
        XCTAssertEqual(model.notice, DevicesWords.removed)
    }

    func testARemovalThatStoppedSaysRemovingAndWhyAndCanBeCarriedOn() async throws {
        let (session, _) = try makeSession(otherTrusted: true, canRemove: false,
                                           otherRemoving: ["since": 1, "done": ["messages"], "stuck": ["step": "coreKey", "why": "Couldn't reach Core"]])
        removalAnswers([(200, #"{"ok":true,"gone":false,"done":["messages"],"stuck":{"step":"coreKey","why":"Couldn't reach Core"}}"#)])
        let model = DevicesModel(session: session)
        await model.load()
        let row = try other(model)
        XCTAssertEqual(OneDeviceListing.note(row), "Removing\u{2026} Couldn't reach Core")
        // it can be asked again from here, though the PC lists it as not removable in one step
        XCTAssertNil(OneDeviceListing.removalBlocked(row, devices: model.devices, thisChat: model.thisDevice))
        XCTAssertTrue(OneDeviceListing.approvable(row, devices: model.devices, thisChat: model.thisDevice).isEmpty)
        await model.removeTapped(row)
        await model.removeTapped(row)
        XCTAssertEqual(model.notice, "Removing\u{2026} Couldn't reach Core")
        XCTAssertFalse(box.all("oneRemove").isEmpty)
    }

    func testThePhoneMayNotRemoveItselfAndSaysSo() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let me = try XCTUnwrap(model.device("t-me"))
        XCTAssertEqual(OneDeviceListing.removalBlocked(me, devices: model.devices, thisChat: model.thisDevice), DevicesWords.removeFromAnother)
        await model.removeTapped(me)
        await model.removeTapped(me)
        XCTAssertNil(model.armed)
        XCTAssertTrue(LiveStub.seen.filter { $0 == "POST /one-devices/remove" }.isEmpty)
        XCTAssertEqual(OneDeviceListing.title(me, thisChat: model.thisDevice), "Mango (this phone)")
    }

    func testTheReasonsThePCGivesForARefusedRemovalAreShownAsTheyCome() throws {
        let me = OneDevice(id: "a", name: "Kiwi", canRemove: false, whyNot: "This is the PC itself",
                           parts: OneParts(chat: [OneChatKey(device: "cd-me", trusted: true, ecdh: "e", sign: "s")]))
        let kiwi = OneDevice(id: "b", name: "Kiwi", canRemove: false, whyNot: "This is the PC itself")
        XCTAssertEqual(OneDeviceListing.removalBlocked(kiwi, devices: [me, kiwi], thisChat: "cd-me"), "This is the PC itself")
        let free = OneDevice(id: "c", name: "Fig")
        XCTAssertNil(OneDeviceListing.removalBlocked(free, devices: [me, free], thisChat: "cd-me"))
    }

    // MARK: renaming and merging

    func testRenamingSendsTheDeviceAndTheNameAndReadsTheListAgain() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let row = try other(model)
        await model.rename(row, to: "  Pear   tree ")
        let sent = try XCTUnwrap(box.json("rename"))
        XCTAssertEqual(sent["thing"] as? String, row.id)
        XCTAssertEqual(sent["name"] as? String, "Pear tree")
        XCTAssertEqual(Set(sent.keys), ["thing", "name"])
        XCTAssertEqual(model.notice, DevicesWords.renamed)
        // a name that is empty, or the one it has, asks nothing
        await model.rename(row, to: "   ")
        await model.rename(row, to: row.name)
        XCTAssertEqual(box.all("rename").count, 1)
    }

    func testMergingNamesWhichDeviceStaysAndSendsNothingBeforeThat() async throws {
        let (session, _) = try makeSession()
        let model = DevicesModel(session: session)
        await model.load()
        let a = try XCTUnwrap(model.device("t-me")), b = try other(model)
        XCTAssertTrue(box.all("merge").isEmpty, "seeing a pair that may be one merges nothing")
        await model.merge(keep: b, gone: a)
        let sent = try XCTUnwrap(box.json("merge"))
        XCTAssertEqual(sent["a"] as? String, "t-other")
        XCTAssertEqual(sent["b"] as? String, "t-me")
        XCTAssertEqual(model.notice, DevicesWords.merged)
    }

    // MARK: the words

    func testWhatARowSaysAndWhatGoesWithIt() {
        let waiting = OneDevice(id: "w", name: "Coconut", kind: "iPhone", waiting: true,
                                parts: OneParts(session: [OneSignIn(id: "s")], chat: [OneChatKey(device: "c", trusted: false, ecdh: "e", sign: "s")]))
        XCTAssertEqual(OneDeviceListing.note(waiting), "iPhone \u{00B7} Signed in \u{00B7} Waiting for approval")
        let pc = OneDevice(id: "k", name: "Kiwi", kind: "PC", parts: OneParts(chat: [OneChatKey(device: "c", trusted: true, ecdh: "e", sign: "s"), OneChatKey(device: "d", trusted: true, ecdh: "e", sign: "s")],
                                                                              key: [OneFileKey(device: "f")]))
        XCTAssertEqual(OneDeviceListing.note(pc), "PC \u{00B7} Chat keys \u{00B7} Files")
        XCTAssertEqual(OneDeviceListing.has(pc), "2 chat keys, 1 file key")
        XCTAssertEqual(OneDeviceListing.when(0), "never")
        XCTAssertEqual(OneDevice(id: "n", name: "").shownName, "A device")
    }

    func testOnlyAnApprovedPhoneApprovesAndNeverItself() {
        func dev(_ id: String, _ chat: String, trusted: Bool) -> OneDevice {
            OneDevice(id: id, name: id, waiting: !trusted, parts: OneParts(chat: [OneChatKey(device: chat, trusted: trusted, ecdh: "e", sign: "s")]))
        }
        let me = dev("me", "cd-me", trusted: true), waiting = dev("w", "cd-w", trusted: false), meWaiting = dev("me", "cd-me", trusted: false)
        XCTAssertEqual(OneDeviceListing.approvable(waiting, devices: [me, waiting], thisChat: "cd-me").count, 1)
        XCTAssertTrue(OneDeviceListing.approvable(me, devices: [me, waiting], thisChat: "cd-me").isEmpty, "an approved device has nothing to approve")
        XCTAssertTrue(OneDeviceListing.approvable(waiting, devices: [meWaiting, waiting], thisChat: "cd-me").isEmpty, "a waiting phone approves nothing")
        XCTAssertTrue(OneDeviceListing.approvable(meWaiting, devices: [meWaiting], thisChat: "cd-me").isEmpty, "and not itself")
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

    func testTheListTheStoreMadeForThisPhonesTrustDecodes() throws {
        let mine = try XCTUnwrap(try DeviceVectors.load()["devices_mine"])
        let answer = try JSONDecoder().decode(DevicesAnswer.self, from: JSONSerialization.data(withJSONObject: mine))
        XCTAssertEqual(answer.now, 1_700_000_000)
        XCTAssertEqual(answer.devices.map(\.trusted), [true, false])
    }
}

/// A failed call never gives this phone a new device identity: the keys kept stay its own, and the failure is shown.
@MainActor
final class DeviceIdentityKeptTests: XCTestCase {
    private var saved: URL?

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

    /// A phone that already has chat keys of its own (raw keys, as an earlier build made them), in a store that records every save.
    private func phone() throws -> (ChatSession, MemoryChatKeyStore, ChatDevice, Data) {
        let have = ChatDevice.software(person: "p1", id: "AAECAwQFBgcICQoL", ecdh: P256.KeyAgreement.PrivateKey(), sign: P256.Signing.PrivateKey())
        let store = MemoryChatKeyStore()
        let kept = try have.kept()
        try store.save(kept, person: "p1")
        LiveStub.json("GET /rooms.json", #"{"me":"owner","me_id":"p1","owner":"Aryn","rooms":[]}"#)
        LiveStub.route("GET /private/unlock/status") { _ in LiveStub.Answer(status: 200, body: Data(#"{"unlocked":true}"#.utf8)) }
        return (ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: store), store, have, kept)
    }

    func testTheOldKeyRenewalRoutesAreNeverAskedAndA404OnThemChangesNothing() async throws {
        let (session, store, have, kept) = try phone()
        var registered: [String] = []
        let lock = NSLock()
        LiveStub.route("POST /devices") { r in
            lock.lock(); registered.append((try? JSONSerialization.jsonObject(with: r.bodyBytes) as? [String: Any])?["device"] as? String ?? ""); lock.unlock()
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"trusted":true,"name":"Mango"}"#.utf8))
        }
        // the PC no longer has these: 404 (a stub with no route answers 404 too)
        LiveStub.route("GET /devices/keys.json") { _ in LiveStub.Answer(status: 404, body: Data("404: Not Found".utf8)) }
        LiveStub.route("POST /devices/proofs") { _ in LiveStub.Answer(status: 404, body: Data("404: Not Found".utf8)) }
        let list = ChatListModel(session: session)
        await list.load()
        _ = try await session.ensureDevice()
        XCTAssertEqual(session.deviceID, have.id)
        XCTAssertEqual(try store.load(person: "p1"), kept, "the keys kept are the same bytes")
        XCTAssertNil(try store.load(person: "p1#next"))
        lock.lock(); let ids = Set(registered); lock.unlock()
        XCTAssertEqual(ids, [have.id], "no other device id was ever registered")
        XCTAssertFalse(LiveStub.seen.contains { $0.contains("devices/keys") || $0.contains("devices/proofs") })
    }

    func testAFailedRegistrationKeepsTheSameKeysAndSaysSoNotMakingANewDevice() async throws {
        for answer in [LiveStub.Answer(status: 404, body: Data("404: Not Found".utf8)),
                       LiveStub.Answer(status: 409, body: Data(#"{"ok":false,"device_removed":true,"error":"This device was removed from your list."}"#.utf8)),
                       LiveStub.Answer(status: 500, body: Data("oops".utf8)), LiveStub.Answer(status: 0, body: Data(), failure: .notConnectedToInternet)] {
            LiveStub.reset()
            let (session, store, have, kept) = try phone()
            var bodies = 0
            let lock = NSLock()
            LiveStub.route("POST /devices") { _ in lock.lock(); bodies += 1; lock.unlock(); return answer }
            do { _ = try await session.ensureDevice(); XCTFail("a failed registration is not a device") } catch {}
            XCTAssertEqual(try store.load(person: "p1"), kept)
            lock.lock(); XCTAssertEqual(bodies, 1, "one try, no second identity"); lock.unlock()
            XCTAssertNil(session.deviceID, "nothing is used as this phone's device until the PC accepted it")
            // asked again later: the same keys, the same id
            LiveStub.route("POST /devices") { _ in LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"trusted":true,"name":"Mango"}"#.utf8)) }
            let back = try await session.ensureDevice()
            XCTAssertEqual(back.id, have.id)
        }
    }

    func testTheChatListShowsAFailedRegistrationWithFindOutWhy() async throws {
        let (session, _, _, _) = try phone()
        LiveStub.route("POST /devices") { _ in LiveStub.Answer(status: 404, body: Data("404: Not Found".utf8)) }
        let list = ChatListModel(session: session)
        await list.load()
        let stopped = try XCTUnwrap(list.stopped)
        XCTAssertTrue(stopped.text.contains(ChatStopWords.settingUp), stopped.text)
        XCTAssertEqual(stopped.action, .retry)
    }
}

final class DeviceCodeTests: XCTestCase {
    /// The PC's test vector (tests/test_device_approval.py, and the page's node run): ("A", "B") gives 610778.
    func testTheCodeIsTheOneTheServerAndThePageMake() {
        XCTAssertEqual(DeviceCode.code(ecdh: "A", sign: "B"), "610778")
        XCTAssertEqual(DeviceCode.shown(DeviceCode.code(ecdh: "A", sign: "B")), "610 778")
        XCTAssertEqual(DeviceCode.code(ecdh: "A", sign: "B").count, 6)
    }

    func testTheCodeOfTheVectorsKeysIsTheStores() throws {
        let v = try DeviceVectors.load()
        let target = try XCTUnwrap(v["target"] as? [String: Any])
        XCTAssertEqual(DeviceCode.code(ecdh: target["ecdh"] as? String ?? "", sign: target["sign"] as? String ?? ""), v["code"] as? String)
    }

    func testTheCodeDependsOnBothKeys() {
        XCTAssertNotEqual(DeviceCode.code(ecdh: "a", sign: "b"), DeviceCode.code(ecdh: "a", sign: "c"))
        XCTAssertNotEqual(DeviceCode.code(ecdh: "a", sign: "b"), DeviceCode.code(ecdh: "x", sign: "b"))
    }
}
