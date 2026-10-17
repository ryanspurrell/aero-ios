import XCTest
import CryptoKit
@testable import Aero

/// Chat without a screen: (the keys and message formats are checked against the reference vectors in ChatVectorTests),
/// what the server's answers decode to, what is drawn on which side, how a failure is worded, and when to stop asking for a reply.
/// All names, messages and keys are invented.
final class ChatTests: XCTestCase {
    // MARK: base64url

    func testBase64UrlHasNoPaddingAndUsesDashAndUnderscore() {
        XCTAssertEqual(ChatBase64.encode(Data([0xfb, 0xff])), "-_8")
        XCTAssertEqual(ChatBase64.decode("-_8"), Data([0xfb, 0xff]))
        XCTAssertEqual(ChatBase64.decode(ChatBase64.encode(Data("hello".utf8))), Data("hello".utf8))
    }

    static func soft(_ person: String) -> ChatDevice {
        ChatDevice.software(person: person, id: ChatBase64.encode(Data((0..<12).map { _ in UInt8.random(in: 0...255) })), ecdh: P256.KeyAgreement.PrivateKey(), sign: P256.Signing.PrivateKey())
    }

    // MARK: opening a stored message

    private func wire(_ seq: Int, kind: String = "person", sender: String = "owner", from d: ChatDevice, key: SymmetricKey, text: String, epoch: Int = 0, room: String = "rabc") throws -> ChatWireMessage {
        let s = try ChatCrypto.encrypt(room: room, epoch: epoch, key: key, text: text, device: d)
        return ChatWireMessage(seq: seq, kind: kind, sender: sender, senderID: d.person, device: d.id, at: 1000 + Double(seq), epoch: epoch, iv: s.iv, ct: s.ct, sig: s.sig, note: nil)
    }

    func testAMessageIsOpenedFromTheAnswersDevices() throws {
        let me = Self.soft("p1")
        let key = ChatCrypto.freshKey()
        let m = try wire(1, from: me, key: key, text: "hello")
        let devices = ["owner": [ChatDeviceInfo(device: me.id, ecdh: me.ecdhPublic, sign: me.signPublic, label: nil, personID: nil, isPrivate: nil)]]
        let e = ChatOpener.entry(m, room: "rabc", keys: ["rabc|0": key], devices: devices, holders: [:], locked: false)
        XCTAssertEqual(e.text, "hello")
        XCTAssertNil(e.unreadable)
    }

    func testWithoutTheKeyOrTheSenderTheLineSaysSo() throws {
        let me = Self.soft("p1")
        let key = ChatCrypto.freshKey()
        let m = try wire(1, from: me, key: key, text: "hello")
        XCTAssertEqual(ChatOpener.entry(m, room: "rabc", keys: [:], devices: [:], holders: [:], locked: false).unreadable, "Sent before you joined")
        XCTAssertEqual(ChatOpener.entry(m, room: "rabc", keys: ["rabc|0": key], devices: [:], holders: [:], locked: false).unreadable, "This message couldn\u{2019}t be verified")
    }

    func testANoteIsPlainAndAReactionDrawsNothing() throws {
        let note = ChatWireMessage(seq: 2, kind: "note", sender: "", senderID: nil, device: nil, at: 5, epoch: nil, iv: nil, ct: nil, sig: nil, note: "Aryn started this")
        XCTAssertEqual(ChatOpener.entry(note, room: "rabc", keys: [:], devices: [:], holders: [:], locked: false).note, "Aryn started this")
        let me = Self.soft("p1")
        let key = ChatCrypto.freshKey()
        let reaction = try JSONSerialization.data(withJSONObject: ["re": "yes"])
        let sealed = try ChatCrypto.lock(reaction, key: key, aad: "rabc|0|p1|\(me.id)")
        let iv = ChatBase64.encode(sealed.iv), ct = ChatBase64.encode(sealed.ct)
        let sig = ChatBase64.encode(try me.signRaw(ChatCrypto.signedPart(room: "rabc", epoch: 0, sender: "p1", device: me.id, iv: iv, ct: ct)))
        let m = ChatWireMessage(seq: 3, kind: "person", sender: "owner", senderID: "p1", device: me.id, at: 6, epoch: 0, iv: iv, ct: ct, sig: sig, note: nil)
        let devices = ["owner": [ChatDeviceInfo(device: me.id, ecdh: me.ecdhPublic, sign: me.signPublic, label: nil, personID: nil, isPrivate: nil)]]
        let e = ChatOpener.entry(m, room: "rabc", keys: ["rabc|0": key], devices: devices, holders: [:], locked: false)
        XCTAssertNil(e.text)
        XCTAssertNil(e.unreadable)
    }

    func testWhoseDeviceSignedAnAIsMessage() {
        func info(_ d: String, priv: Bool = false) -> ChatDeviceInfo { ChatDeviceInfo(device: d, ecdh: "", sign: "", label: nil, personID: nil, isPrivate: priv) }
        let ai = ChatWireMessage(seq: 1, kind: "model", sender: "fingus", senderID: nil, device: "dev9", at: nil, epoch: 0, iv: "", ct: "", sig: "", note: nil)
        XCTAssertEqual(ChatOpener.signer(of: ai, locked: false, devices: [:], holders: [:]), "@pc")
        XCTAssertEqual(ChatOpener.signer(of: ai, locked: false, devices: ["@fingoid": [info("dev9")]], holders: [:]), "@fingoid")
        XCTAssertEqual(ChatOpener.signer(of: ai, locked: true, devices: ["owner": [info("dev9", priv: true)]], holders: [:]), "owner")
        XCTAssertEqual(ChatOpener.signer(of: ai, locked: false, devices: ["owner": [info("dev9", priv: true)]], holders: [:]), "@pc")
        let addon = ChatWireMessage(seq: 2, kind: "addon", sender: "council", senderID: nil, device: "d", at: nil, epoch: 0, iv: "", ct: "", sig: "", note: nil)
        XCTAssertEqual(ChatOpener.signer(of: addon, locked: false, devices: [:], holders: ["council": "@council"]), "@council")
    }

    // MARK: what the server answers

    func testTheRoomsAnswerDecodes() throws {
        let json = """
        {"me":"owner","me_id":"p1","owner":"Aryn","rooms":[
          {"id":"r1","name":"","direct":false,"pinned":true,"touched":10.5,"last":4,"unread":2,"epoch":0,"ai":true,"private":false,"answers":"aero","manager":"fingus","members":[{"kind":"person","name":"owner","nick":null},{"kind":"model","name":"fingus","nick":null}]},
          {"id":"r2","name":"Plans","private":true,"members":[]}]}
        """
        let a = try JSONDecoder().decode(ChatRoomsAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.person, "p1")
        XCTAssertEqual(a.rooms.map(\.id), ["r1", "r2"])
        XCTAssertFalse(a.rooms[0].locked)
        XCTAssertTrue(a.rooms[1].locked)
    }

    func testTheRoomAnswerDecodesWithWritingAndSeals() throws {
        let json = """
        {"id":"r1","name":null,"epoch":2,"ai":true,"private":false,"me":"owner","owner":"Aryn",
         "members":[{"kind":"person","name":"owner","nick":null,"model":null},{"kind":"model","name":"fingus","model":"llama"}],
         "messages":[{"seq":1,"kind":"note","sender":"","device":null,"at":1.5,"epoch":null,"iv":null,"ct":null,"sig":null,"note":"Aryn started this"}],
         "seals":[{"epoch":0,"by_person":"p1","by_device":"dA","iv":"aaaa","ct":"bbbb"}],
         "devices":{"@pc":[{"device":"pc","ecdh":"x","sign":"y","label":"","added":1,"private":0},{"device":"d2","ecdh":"x2","sign":"y2","private":true}]},
         "writing":[{"name":"fingus","live":{"room":"r1","kind":"model","sender":"fingus","device":"pc","epoch":0,"iv":"aaaa","ct":"bbbb"},"stage":"","work":[]},{"name":"x","live":null,"stage":"thinking"}],
         "holders":{}}
        """
        let a = try JSONDecoder().decode(ChatRoomAnswer.self, from: Data(json.utf8))
        XCTAssertEqual(a.epoch, 2)
        XCTAssertEqual(a.seals.first?.byDevice, "dA")
        XCTAssertEqual(a.writing?.first?.live?.sender, "fingus")
        XCTAssertNil(a.writing?.last?.live)
        XCTAssertEqual(a.messages.first?.note, "Aryn started this")
        // the store keeps `private` as 0 or 1; either form is read
        XCTAssertEqual(a.devices["@pc"]?.map { $0.isPrivate ?? false }, [false, true])
    }

    func testTheServersRefusalsAreToldApart() {
        XCTAssertEqual(ChatAPI.failure(status: 401, data: Data(#"{"error":"Locked","locked":true}"#.utf8)), .locked)
        XCTAssertEqual(ChatAPI.failure(status: 401, data: Data()), .notSignedIn)
        XCTAssertEqual(ChatAPI.failure(status: 400, data: Data(#"{"error":"key has changed"}"#.utf8)), .server("key has changed"))
        XCTAssertEqual(ChatAPI.failure(status: 500, data: Data()), .server("That didn't work. Try again."))
        XCTAssertNil(ChatAPI.failure(status: 200, data: Data("{}".utf8)))
    }

    func testAddressesAreBuiltUnderTheAddressTheAppWasGiven() {
        let base = URL(string: "https://aero.example.ts.net/aero/")!
        XCTAssertEqual(ChatAPI.url(base: base, path: "rooms.json")?.absoluteString, "https://aero.example.ts.net/aero/rooms.json")
        XCTAssertEqual(ChatAPI.url(base: base, path: "rooms/r1.json", query: ["device": "d-_1", "after": "4"])?.absoluteString,
                       "https://aero.example.ts.net/aero/rooms/r1.json?after=4&device=d-_1")
    }

    // MARK: what is drawn

    private func entry(_ seq: Int, _ kind: String, _ sender: String, _ text: String?, unreadable: String? = nil, note: String? = nil) -> ChatEntry {
        ChatEntry(seq: seq, kind: kind, sender: sender, text: text, note: note, at: Double(seq), unreadable: unreadable)
    }

    func testYourWordsAreOnOneSideAndRepliesOnTheOther() {
        let lines = ChatTranscript.lines(entries: [entry(1, "note", "", nil, note: "Aryn started this"), entry(2, "person", "owner", "hi"), entry(3, "model", "fingus", "hello")],
                                         me: "owner", writing: [], showSpeakers: false, shown: { $0 })
        XCTAssertEqual(lines.map(\.side), [.note, .mine, .theirs])
        XCTAssertEqual(lines.map(\.text), ["Aryn started this", "hi", "hello"])
        XCTAssertNil(lines[2].speaker)
    }

    func testAReplyBeingWrittenIsTheLastLineAndIsNotShownTwiceOnceItIsDone() {
        let writing = [ChatWriting(name: "fingus", text: "Sure, here", stage: nil)]
        let during = ChatTranscript.lines(entries: [entry(2, "person", "owner", "hi")], me: "owner", writing: writing, showSpeakers: false, shown: { $0 })
        XCTAssertEqual(during.last?.text, "Sure, here")
        XCTAssertEqual(during.last?.streaming, true)
        let both = ChatTranscript.lines(entries: [entry(2, "person", "owner", "hi"), entry(3, "model", "fingus", "Sure, here")], me: "owner",
                                        writing: [ChatWriting(name: "fingus", text: "Sure, here", stage: nil)], showSpeakers: false, shown: { $0 })
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.filter(\.streaming).count, 0)
    }

    func testWithNoAuthenticatedWordsOnlyTheStageMarkIsShown() {
        let l = ChatTranscript.lines(entries: [], me: "owner", writing: [ChatWriting(name: "fingus", text: nil, stage: "thinking")], showSpeakers: false, shown: { $0 })
        XCTAssertEqual(l.first?.text, "thinking")
        XCTAssertEqual(l.first?.streaming, true)
    }

    func testAReplyThatHasNotSaidAnythingYetIsStillALine() {
        let l = ChatTranscript.lines(entries: [], me: "owner", writing: [ChatWriting(name: "fingus", text: nil, stage: nil)], showSpeakers: false, shown: { $0 })
        XCTAssertEqual(l.count, 1)
        XCTAssertTrue(l[0].streaming)
        XCTAssertEqual(l[0].text, "")
    }

    func testAnUnreadableMessageShowsItsReasonAndNothingElse() {
        let l = ChatTranscript.lines(entries: [entry(1, "person", "owner", nil, unreadable: "Sent before you joined")], me: "owner", writing: [], showSpeakers: false, shown: { $0 })
        XCTAssertEqual(l.first?.text, "Sent before you joined")
        XCTAssertEqual(l.first?.unreadable, true)
    }

    func testAnotherPersonsWordsNameThem() {
        let l = ChatTranscript.lines(entries: [entry(1, "person", "sam", "hi")], me: "owner", writing: [], showSpeakers: false, shown: { $0.capitalized })
        XCTAssertEqual(l.first?.speaker, "Sam")
    }

    // MARK: the list

    func testAChatIsCalledByItsNameOrByWhoIsInIt() {
        let ai = ChatMember(kind: "model", name: "fingus", nick: nil, model: nil)
        let me = ChatMember(kind: "person", name: "owner", nick: nil, model: nil)
        XCTAssertEqual(ChatListing.title(ChatRoomRow(id: "r1", name: "Plans", members: [me, ai]), me: "owner"), "Plans")
        XCTAssertEqual(ChatListing.title(ChatRoomRow(id: "r1", name: "", members: [me, ai]), me: "owner"), "Fingus")
        XCTAssertEqual(ChatListing.title(ChatRoomRow(id: "r1", name: nil, members: [me]), me: "owner"), "Just you")
        XCTAssertEqual(ChatListing.title(ChatRoomRow(id: "r1", name: nil, members: [me, ChatMember(kind: "person", name: "sam", nick: "Sammy", model: nil)]), me: "owner"), "Sammy")
    }

    func testPinnedChatsComeFirstAndLockedOnesOnlyWhileLockedIsOpen() {
        let rows = [ChatRoomRow(id: "a"), ChatRoomRow(id: "b", pinned: true), ChatRoomRow(id: "c", isLocked: true), ChatRoomRow(id: "d", pinned: true, isLocked: true)]
        XCTAssertEqual(ChatListing.order(rows, lockedOpen: false).map(\.id), ["b", "a"])
        XCTAssertEqual(ChatListing.order(rows, lockedOpen: true).map(\.id), ["b", "d", "a", "c"])
    }

    func testUnreadWordsAreQuiet() {
        XCTAssertNil(ChatListing.unreadWords(ChatRoomRow(id: "a", unread: 0)))
        XCTAssertEqual(ChatListing.unreadWords(ChatRoomRow(id: "a", unread: 3)), "3 new")
        XCTAssertEqual(ChatWords.rowNote("3 new", locked: true), "Locked \u{00B7} 3 new")
        XCTAssertNil(ChatWords.rowNote(nil, locked: false))
    }

    // MARK: starting a chat

    func testAModelForALockedChatRunsOnThePC() {
        let models = ["claude-sonnet", "codex", "llama3:cloud", "auto", "llama3", "qwen"]
        XCTAssertEqual(ChatModelPick.pick(from: models, privacy: .open), "claude-sonnet")
        XCTAssertEqual(ChatModelPick.pick(from: models, privacy: .locked), "llama3")
        XCTAssertNil(ChatModelPick.pick(from: ["claude-sonnet"], privacy: .locked))
        XCTAssertNil(ChatModelPick.pick(from: [], privacy: .open))
    }

    func testOpenAndLockedAreNamedAndExplainedInThePagesOwnWords() {
        XCTAssertEqual(ChatPrivacy.allCases.map(\.title), ["Open", "Locked"])
        XCTAssertEqual(ChatPrivacy.open.line, "Kept on your PC and the phones in it")
        XCTAssertTrue(ChatPrivacy.locked.line.contains("nothing leaves it"))
    }

    // MARK: waiting for a reply

    func testAskingContinuesWhileAReplyIsWrittenAndStopsOnceItHasArrived() {
        XCTAssertTrue(ChatPollPlan.shouldContinue(writing: true, busy: false, sawReply: false, secondsSinceSend: 100))
        XCTAssertTrue(ChatPollPlan.shouldContinue(writing: false, busy: true, sawReply: true, secondsSinceSend: 100))
        XCTAssertTrue(ChatPollPlan.shouldContinue(writing: false, busy: false, sawReply: false, secondsSinceSend: 2))
        XCTAssertFalse(ChatPollPlan.shouldContinue(writing: false, busy: false, sawReply: true, secondsSinceSend: 2))
        XCTAssertFalse(ChatPollPlan.shouldContinue(writing: false, busy: false, sawReply: false, secondsSinceSend: ChatPollPlan.waitForStart + 1))
    }

    // MARK: when something stops

    func testEveryFailureIsOneShapeWithAKey() {
        let cases: [(Error, String, ChatStopped.Action)] = [
            (ChatAPI.Failure.locked, "the lock", .unlock),
            (ChatAPI.Failure.notSignedIn, "signing in", .retry),
            (ChatAPI.Failure.noAddress, "finding Aero's address", .retry),
            (ChatAPI.Failure.server("x"), "Aero's answer", .retry),
            (URLError(.notConnectedToInternet), "reaching Aero", .retry),
            (ChatCryptoError.cannotOpen, "reading it on this phone", .retry),
            (ChatSessionError.noKey, "reading it on this phone", .retry),
            (ChatKeyError.unreadable(-25308), "reading it on this phone", .retry),
        ]
        for (error, step, action) in cases {
            let s = ChatStopWords.make(doing: ChatStopWords.sending, error: error)
            XCTAssertEqual(s.step, step)
            XCTAssertEqual(s.action, action)
            XCTAssertTrue(s.text.hasPrefix("Sending your message stopped at \(step). "), s.text)
            XCTAssertFalse(s.key.isEmpty)
            XCTAssertTrue(s.text.hasSuffix("."))
        }
        XCTAssertEqual(ChatStopWords.make(doing: ChatStopWords.sending, error: ChatAPI.Failure.locked).key, "Unlock in Aero")
    }

    // MARK: too many chat devices

    func testARefusalForTooManyDevicesIsRecognisedWithItsNumber() {
        XCTAssertEqual(ChatAPI.failure(status: 409, data: Data(#"{"error":"This phone can't be added: you have 8 devices. Remove one in Devices.","devices_full":8}"#.utf8)), .devicesFull(8))
        // a number that could not be read is still this refusal
        XCTAssertEqual(ChatAPI.failure(status: 409, data: Data(#"{"error":"x","devices_full":0}"#.utf8)), .devicesFull(0))
        // any other refusal is still Aero's own words, and a sign-in problem is still one
        XCTAssertEqual(ChatAPI.failure(status: 409, data: Data(#"{"error":"another"}"#.utf8)), .server("another"))
        XCTAssertEqual(ChatAPI.failure(status: 403, data: Data()), .notSignedIn)
        // an answer that says it succeeded is never taken for the refusal
        XCTAssertNil(ChatAPI.failure(status: 200, data: Data(#"{"ok":true,"devices_full":8}"#.utf8)))
    }

    func testTooManyDevicesIsSaidAsItIsNotAsAerosAnswer() {
        let s = ChatStopWords.make(doing: ChatStopWords.opening, error: ChatAPI.Failure.devicesFull(8))
        XCTAssertEqual(s.text, "This phone can't be added: you have 8 devices. Remove one in Devices.")
        XCTAssertFalse(s.text.contains("Aero's answer"))
        XCTAssertEqual(s.action, .retry)
        XCTAssertEqual(s.key, "Try again")
        XCTAssertEqual(ChatStopWords.make(doing: ChatStopWords.sending, error: ChatAPI.Failure.devicesFull(0)).text,
                       "This phone can't be added: you have too many devices. Remove one in Devices.")
        // the others still come in the one shape
        XCTAssertEqual(ChatStopWords.make(doing: ChatStopWords.opening, error: ChatAPI.Failure.server("x")).text,
                       "Opening this chat stopped at Aero's answer. Try again.")
    }

    func testRemovingADeviceSaysWhetherLosingItsChatsIsKnown() throws {
        func json(_ body: ChatAPI.RemoveBody) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as? [String: Any] ?? [:]
        }
        let plain = try json(ChatAPI.RemoveBody(device: "abc12345", loseHistory: false))
        XCTAssertEqual(plain["device"] as? String, "abc12345")
        XCTAssertEqual(plain["lose_history"] as? Bool, false)
        XCTAssertEqual(try json(ChatAPI.RemoveBody(device: "abc12345", loseHistory: true))["lose_history"] as? Bool, true)
    }

    func testADeviceAeroDoesNotListIsAlreadyGone() {
        XCTAssertTrue(ChatAPI.alreadyGone(.server("That device isn't in your list.")))
        // any other answer is not "done": the id is kept and asked again
        XCTAssertFalse(ChatAPI.alreadyGone(.server("That didn't work. Try again.")))
        XCTAssertFalse(ChatAPI.alreadyGone(.notSignedIn))
        // Aero's own 404 words decode to exactly that case
        XCTAssertEqual(ChatAPI.failure(status: 404, data: Data(#"{"ok":false,"error":"That device isn't in your list."}"#.utf8)), .server(ChatAPI.notInList))
        // and the refusal that closes a chat for good is a refusal, not "gone"
        let holds = ChatAPI.failure(status: 409, data: Data(#"{"ok":false,"error":"Only this device can open 1 chat. Removing it closes it for good. Tap again to remove it anyway.","holds":{"rooms":1,"epochs":1}}"#.utf8))
        XCTAssertNotNil(holds)
        XCTAssertFalse(ChatAPI.alreadyGone(holds!))
    }

    func testThisAppIsNamedAsAnAppInTheDevicesList() {
        XCTAssertEqual(ChatWords.deviceLabel, "iPhone (Aero app)")
        XCTAssertTrue(ChatWords.deviceLabel.count <= 40)
    }

    func testNoWordOfChatHasAnEmoji() {
        let words: [String] = [ChatWords.tab, ChatWords.listTitle, ChatWords.newChat, ChatWords.empty, ChatWords.composerPrompt, ChatWords.send, ChatWords.stop,
                               ChatWords.back, ChatWords.startTitle, ChatWords.startNote, ChatWords.lockedNeedsUnlock, ChatWords.unlockKey, ChatWords.lockedShut,
                               ChatWords.waitingForKeys, ChatWords.lockedTitle, ChatWords.deviceLabel, ChatWords.devicesFull(8), ChatWords.devicesFull(0), ChatOpener.beforeYouJoined, ChatOpener.notVerified, ChatOpener.notOpened,
                               ChatPrivacy.open.line, ChatPrivacy.locked.line]
        for w in words {
            for scalar in w.unicodeScalars { XCTAssertFalse(scalar.properties.isEmojiPresentation, w) }
        }
    }
}
