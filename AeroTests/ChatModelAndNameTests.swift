import XCTest
@testable import Aero

/// What a chat is called in the list, and which model answers and how it is switched. All names, models and times are invented.
final class ChatNamingTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private let en = Locale(identifier: "en_US")
    private let ai = ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")
    private let me = ChatMember(kind: "person", name: "owner", nick: nil, model: nil)
    /// 2023-11-14 22:13:20 UTC
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func title(_ row: ChatRoomRow, firstWords: String? = nil) -> String {
        ChatListing.title(row, me: "owner", firstWords: firstWords, now: now, calendar: utc, locale: en)
    }

    func testTheNameTheRoomIsGivenIsWhatTheListShows() {
        // the PC names a chat after a few messages; the phone shows that name, never "Fingus"
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: "Pasta for Friday", touched: 1_700_000_000, members: [me, ai])), "Pasta for Friday")
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: "  Pasta for Friday ", members: [ai])), "Pasta for Friday")
        // and her own name for it, the same field
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: "Fingus", members: [ai])), "Fingus", "a name someone gave it is shown as it is")
    }

    func testAChatWithOnlyTheAIIsNotCalledByTheAIsName() {
        for name in [nil, ""] as [String?] {
            let t = title(ChatRoomRow(id: "r", name: name, touched: 1_700_000_000, members: [me, ai]))
            XCTAssertNotEqual(t, "Fingus")
            XCTAssertTrue(t.hasPrefix("Today, 10:13"), t)
        }
    }

    func testAnUnnamedChatShowsItsFirstWordsWhenTheyAreKnownHere() {
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: "", touched: 5, members: [ai]), firstWords: "What is on for Saturday?"), "What is on for Saturday?")
    }

    func testOtherDaysAreSaidAsYesterdayOrTheDate() {
        let yesterday = title(ChatRoomRow(id: "r", name: nil, touched: 1_700_000_000 - 86_400, members: [ai]))
        XCTAssertTrue(yesterday.hasPrefix("Yesterday, 10:13"), yesterday)
        let older = title(ChatRoomRow(id: "r", name: nil, touched: 1_700_000_000 - 5 * 86_400, members: [ai]))
        XCTAssertTrue(older.hasPrefix("Nov 9, 10:13"), older)
    }

    func testAChatWithNothingToGoOnIsNewChatAndAChatWithPeopleIsCalledByThem() {
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: nil, members: [me, ai])), ChatWords.newChat)
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: nil, members: [me, ChatMember(kind: "person", name: "sam", nick: "Sammy", model: nil), ai])), "Sammy")
        XCTAssertEqual(title(ChatRoomRow(id: "r", name: nil, members: [me])), "Just you")
    }

    func testFirstWordsAreShortOnOneLine() {
        XCTAssertEqual(ChatListing.firstWords(of: "  What is\n on   for Saturday? "), "What is on for Saturday?")
        XCTAssertEqual(ChatListing.firstWords(of: "one two three four five six seven eight"), "one two three four five six")
        let long = ChatListing.firstWords(of: "supercalifragilisticexpialidocious pneumonoultramicroscopic")
        XCTAssertEqual(long?.hasSuffix("\u{2026}"), true)
        XCTAssertLessThanOrEqual(long?.count ?? 99, ChatListing.firstWordsLength + 1)
        XCTAssertNil(ChatListing.firstWords(of: "   \n "))
    }

    @MainActor
    func testTheListNamesRowsFromTheSessionsFirstWordsButNeverForALockedChat() {
        let session = ChatSession(api: ChatAPI(), keyStore: MemoryChatKeyStore())
        session.noteFirstWords(room: "open", from: "Plan the garden beds", locked: false)
        session.noteFirstWords(room: "locked", from: "something private", locked: true)
        XCTAssertEqual(session.firstWords["open"], "Plan the garden beds")
        XCTAssertNil(session.firstWords["locked"])
        let list = ChatListModel(session: session)
        XCTAssertEqual(list.title(ChatRoomRow(id: "open", name: nil, members: [ai])), "Plan the garden beds")
        // a later name from the PC wins
        XCTAssertEqual(list.title(ChatRoomRow(id: "open", name: "Garden", members: [ai])), "Garden")
        session.reset()
        XCTAssertTrue(session.firstWords.isEmpty, "gone with the account")
    }

    func testTheModelIsSaidInPlainWords() {
        XCTAssertEqual(ChatModelPick.shown("llama-demo:8b"), "llama-demo:8b")
        XCTAssertEqual(ChatModelPick.shown("auto"), "Automatic")
        XCTAssertEqual(ChatModelPick.shown("auto:fast"), "Automatic: fast")
        XCTAssertEqual(ChatModelPick.note("llama-demo:8b"), "Runs on your PC")
        XCTAssertEqual(ChatModelPick.note("claude-demo"), "Gets this chat's messages, through Anthropic")
        XCTAssertEqual(ChatModelPick.note("some-model:cloud"), "Gets this chat's messages")
        XCTAssertTrue(ChatWords.modelLabel("llama-demo:8b").hasSuffix("Change"))
    }

    func testTheChoicesAreThePagesAndALockedChatOnlyGetsLocalOnes() {
        let offered = ["auto", "llama-demo:8b", "claude-demo", "qwen-demo:4b", "big:cloud"]
        XCTAssertEqual(ChatModelPick.choices(from: offered, privacy: .open, current: "llama-demo:8b"), offered)
        XCTAssertEqual(ChatModelPick.choices(from: offered, privacy: .locked, current: "llama-demo:8b"), ["llama-demo:8b", "qwen-demo:4b"])
        // the model it has now is listed first when Aero no longer offers it
        XCTAssertEqual(ChatModelPick.choices(from: ["llama-demo:8b"], privacy: .open, current: "old-model:7b"), ["old-model:7b", "llama-demo:8b"])
    }
}

@MainActor
final class ChatModelSwitchTests: XCTestCase {
    private var saved: URL?
    private let box = StubBox()
    private let room = "r0123456789abcdef"

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

    private func roomJSON(model: String, name: String? = nil) -> String {
        let n = name.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(room)","name":\#(n),"epoch":0,"ai":true,"private":false,"me":"owner","owner":"Aryn","members":[{"kind":"person","name":"owner","nick":null,"model":null},{"kind":"model","name":"fingus","model":"\#(model)"}],"messages":[],"seals":[],"devices":{},"holders":{}}"#
    }

    /// An Aero that holds one chat whose model can be switched; `current` is what it holds now.
    private func serve() -> ChatSession {
        box.set("model", "llama-demo:8b")
        box.set("name", "")
        LiveStub.json("GET /rooms.json", #"{"me":"owner","me_id":"p1","owner":"Aryn","rooms":[]}"#)
        LiveStub.route("POST /devices") { _ in LiveStub.Answer(status: 200, body: Data(#"{"ok":true,"trusted":true,"name":"Mango"}"#.utf8)) }
        LiveStub.route("GET /devices/mine.json") { _ in LiveStub.Answer(status: 404, body: Data()) }
        LiveStub.route("GET /private/unlock/status") { _ in LiveStub.Answer(status: 200, body: Data(#"{"unlocked":true}"#.utf8)) }
        LiveStub.route("GET /rooms/\(room).json") { _ in
            let name = self.box.get("name")
            return LiveStub.Answer(status: 200, body: Data(self.roomJSON(model: self.box.get("model"), name: name.isEmpty ? nil : name).utf8))
        }
        LiveStub.json("POST /rooms/\(room)/read", #"{"ok": true}"#)
        LiveStub.json("GET /rooms/people.json", #"{"models":["auto","llama-demo:8b","claude-demo","qwen-demo:4b"]}"#)
        LiveStub.route("POST /rooms/\(room)/ai") { r in
            self.box.add("ai", r.bodyBytes)
            if let model = (try? JSONSerialization.jsonObject(with: r.bodyBytes) as? [String: Any])?["fields"] as? [String: Any], let m = model["model"] as? String {
                if m == "refused-model" { return LiveStub.Answer(status: 400, body: Data(#"{"error":"you cannot use refused-model"}"#.utf8)) }
                self.box.set("model", m)
            }
            return LiveStub.Answer(status: 200, body: Data(#"{"name":"fingus"}"#.utf8))
        }
        LiveStub.route("POST /rooms/\(room)/name") { r in
            self.box.add("name", r.bodyBytes)
            if let n = (try? JSONSerialization.jsonObject(with: r.bodyBytes) as? [String: Any])?["name"] as? String { self.box.set("name", n) }
            return LiveStub.Answer(status: 200, body: Data(#"{"ok":true}"#.utf8))
        }
        return ChatSession(api: ChatAPI(session: LiveStub.session()), keyStore: MemoryChatKeyStore())
    }

    private func openChat(_ session: ChatSession, locked: Bool = false) -> ChatRoomModel {
        ChatRoomModel(session: session, room: ChatRoomRow(id: room, name: nil, isLocked: locked, members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")]), privacy: .open)
    }

    func testTheChatSaysWhichModelIsAnsweringFromTheRowAndThenFromAero() async {
        let session = serve()
        let model = openChat(session)
        XCTAssertEqual(model.modelName, "llama-demo:8b", "known before the chat is read")
        box.set("model", "qwen-demo:4b")
        await model.load()
        XCTAssertEqual(model.modelName, "qwen-demo:4b", "what Aero holds now")
    }

    func testSwitchingTheModelAsksAeroForTheMemberAndShowsWhatItHolds() async throws {
        let session = serve()
        let model = openChat(session)
        await model.load()
        await model.loadChoices()
        XCTAssertEqual(model.modelChoices, ["auto", "llama-demo:8b", "claude-demo", "qwen-demo:4b"])
        await model.chooseModel("qwen-demo:4b")
        XCTAssertNil(model.stopped)
        let sent = try XCTUnwrap(box.json("ai"))
        XCTAssertEqual(sent["name"] as? String, "fingus")
        XCTAssertEqual((sent["fields"] as? [String: Any])?["model"] as? String, "qwen-demo:4b")
        XCTAssertEqual(Set((sent["fields"] as? [String: Any] ?? [:]).keys), ["model"], "only the model changes")
        XCTAssertEqual(model.modelName, "qwen-demo:4b")
        // choosing the one already in use asks nothing
        await model.chooseModel("qwen-demo:4b")
        XCTAssertEqual(box.all("ai").count, 1)
    }

    func testAModelAeroRefusesIsSaidInTheOneShapeAndTheOldOneStays() async throws {
        let session = serve()
        let model = openChat(session)
        await model.load()
        await model.chooseModel("refused-model")
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains(ChatStopWords.changingModel), said)
        XCTAssertTrue(said.contains("you cannot use refused-model"), said)
        XCTAssertEqual(model.modelName, "llama-demo:8b")
    }

    func testALockedChatOnlyOffersModelsThatRunOnThePC() async {
        let session = serve()
        let model = ChatRoomModel(session: session, room: ChatRoomRow(id: room, name: nil, isLocked: true, members: [ChatMember(kind: "model", name: "fingus", nick: nil, model: "llama-demo:8b")]), privacy: .open)
        XCTAssertEqual(model.privacy, .locked)
        await model.loadChoices()
        XCTAssertEqual(model.modelChoices, ["llama-demo:8b", "qwen-demo:4b"])
    }

    func testANewChatShowsTheModelItWillStartWithAndTakesAnotherBeforeItStarts() async {
        let session = serve()
        let model = ChatRoomModel(session: session, room: nil, privacy: .open)
        await model.load()
        XCTAssertEqual(model.modelName, "auto", "the first Aero offers")
        XCTAssertEqual(model.modelChoices, ["auto", "llama-demo:8b", "claude-demo", "qwen-demo:4b"])
        await model.chooseModel("qwen-demo:4b")
        XCTAssertEqual(model.modelName, "qwen-demo:4b")
        XCTAssertTrue(box.all("ai").isEmpty, "nothing exists on the PC to change yet")
    }

    func testANewLockedChatStartsWithAModelOnThePC() async {
        let session = serve()
        let model = ChatRoomModel(session: session, room: nil, privacy: .locked)
        await model.load()
        XCTAssertEqual(model.modelName, "llama-demo:8b")
        XCTAssertEqual(model.modelChoices, ["llama-demo:8b", "qwen-demo:4b"])
    }

    func testRenamingKeepsHerNameAndEmptyLetsTheChatBeNamedAgain() async throws {
        let session = serve()
        let model = openChat(session)
        await model.load()
        await model.rename(to: "  Garden beds ")
        XCTAssertEqual(try XCTUnwrap(box.json("name"))["name"] as? String, "Garden beds")
        XCTAssertEqual(model.title, "Garden beds")
        await model.rename(to: "   ")
        XCTAssertEqual(try XCTUnwrap(box.json("name"))["name"] as? String, "")
        XCTAssertEqual(model.title, ChatWords.newChat)
    }

    func testARenameAeroRefusesIsSaid() async throws {
        let session = serve()
        LiveStub.route("POST /rooms/\(room)/name") { _ in LiveStub.Answer(status: 400, body: Data(#"{"error":"that name is too long"}"#.utf8)) }
        let model = openChat(session)
        await model.load()
        await model.rename(to: "x")
        let said = try XCTUnwrap(model.stopped).text
        XCTAssertTrue(said.contains(ChatStopWords.renaming) && said.contains("that name is too long"), said)
    }
}
