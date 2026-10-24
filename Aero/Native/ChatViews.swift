import SwiftUI

// Chat, drawn like Messages: the list of chats; a chat with your words on the right and replies on the left, a box and a Send key at the
// bottom; the reply grows in place as it is written. Look is Aero's (Tokens.swift); nothing uses the system's navigation bar or list styles.
//
// Pages stack: the chat list comes in from the right over the calendar, a chat over the list, and back moves them off the same way. Every
// movement has a visible key as well (Back, New chat, Send, Stop the reply); there is no gesture that is the only way to do a thing.

private let pageSpring = Animation.spring(response: Look.springResponse, dampingFraction: Look.springDamping)

/// The chat list and the chats opened from it.
struct ChatScreen: View {
    /// Back to the calendar.
    var back: () -> Void
    /// Opens Aero's page, where Face ID unlocks Locked.
    var unlock: () -> Void
    /// Changes when the page was closed, so Locked is asked about again.
    var returned: Int

    @StateObject private var session = ChatSessionBox()
    @State private var list: ChatListModel?
    @State private var room: ChatRoomModel?
    @State private var choosing = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            if let list {
                ChatListPage(model: list, back: back, newChat: { choosing = true },
                             open: { row in withAnimation(pageSpring) { room = ChatRoomModel(session: list.session, room: row, privacy: .open) } })
            } else {
                ProgressView()
            }
            if let room {
                ChatRoomPage(model: room, back: { leave() }, unlock: unlock)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .fingusGround()
        // leaving Chat (or another address): the keys and everything drawn go with it
        .onDisappear { session.session.reset() }
        .sheet(isPresented: $choosing) {
            if let list {
                StartChatSheet(lockedOpen: list.lockedOpen, unlock: { choosing = false; unlock() }) { privacy in
                    choosing = false
                    withAnimation(pageSpring) { room = ChatRoomModel(session: list.session, room: nil, privacy: privacy) }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .task {
            if list == nil {
                list = ChatListModel(session: session.session)
                // the account changed or signed out: what was drawn for the last one goes
                session.session.onReset = {
                    list?.clear()
                    room?.clearAll()
                    room = nil
                }
            }
            await list?.load()
            if DemoMode.page == "chat", room == nil, let list, let first = DemoMode.chatRows.first { room = ChatRoomModel(session: list.session, room: first, privacy: .open) }
        }
        // the web view was open: it may have signed out or into another account, so nothing held for the last one is kept
        .onChange(of: returned) { _ in
            session.session.reset()
            Task { await list?.load() }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                Task { await list?.load() }
                if let room, room.privacy == .locked { Task { await room.load() } }
            } else {
                // Locked closes with the app: nothing of it stays drawn
                list?.closeLocked()
                room?.shut()
            }
        }
    }

    private func leave() {
        room?.leave()
        withAnimation(pageSpring) { room = nil }
        Task { await list?.load() }
    }
}

/// Holds the session for the screen's life (a @StateObject needs an ObservableObject).
@MainActor
final class ChatSessionBox: ObservableObject {
    let session = ChatSession()
}

// MARK: the list

private struct ChatListPage: View {
    @ObservedObject var model: ChatListModel
    var back: () -> Void
    var newChat: () -> Void
    var open: (ChatRoomRow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text("Today").fx(Look.Size.tab, style: .subheadline)
                    }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel("Back to today")
                Spacer()
                ConnectionIsland()
                Button(action: newChat) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .bold))
                        Text(ChatWords.newChat).fx(Look.Size.pill, style: .footnote)
                    }
                    .foregroundStyle(Look.Palette.ink)
                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                    .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            .padding(.horizontal, Look.Space.gutter)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Look.Space.snug) {
                    Text(ChatWords.listTitle).fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    if let notice = model.renewedNotice {
                        Text(notice).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    if let choice = model.renewalChoice {
                        ChatRenewalChoiceNote(rooms: choice.rooms, accept: { Task { await model.acceptRenewalLoss() } }, decline: { model.declineRenewalLoss() })
                    }
                    if let waiting = model.waiting {
                        ChatWaitingNote(name: waiting.name, code: model.session.deviceCode, check: { Task { await model.load() } })
                    }
                    if let stopped = model.stopped {
                        ChatStoppedNote(stopped: stopped, key: { Task { await model.load() } })
                    }
                    if model.shown.isEmpty && model.loaded && model.stopped == nil {
                        Text(ChatWords.empty).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).padding(.top, Look.Space.gap)
                    }
                    ForEach(model.shown) { row in
                        ChatRow(row: row, title: model.title(row)) { open(row) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Look.Space.gutter)
                .padding(.top, Look.Space.hair)
                .padding(.bottom, Look.Space.gutter)
                .animation(pageSpring, value: model.shown.map(\.id))
            }
        }
    }
}

private struct ChatRow: View {
    let row: ChatRoomRow
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Look.Space.snug) {
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
                    if let note = ChatWords.rowNote(ChatListing.unreadWords(row), locked: row.locked) {
                        HStack(spacing: Look.Space.hair) {
                            if row.locked { Image(systemName: "lock.fill").font(.system(size: 11, weight: .bold)) }
                            Text(note).fx(Look.Size.itemMeta, style: .footnote)
                        }
                        .foregroundStyle(Look.Palette.soft)
                    }
                }
                Spacer(minLength: 0)
                if row.pinned == true { Image(systemName: "pin.fill").font(.system(size: 12)).foregroundStyle(Look.Palette.soft).accessibilityLabel("Pinned") }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Look.Palette.dim)
            }
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
            .fingusCard(radius: Look.Bubble.radiusRow)
        }
        .buttonStyle(BubblePressStyle())
    }
}

// MARK: starting a chat: Open or Locked, before anything is said

private struct StartChatSheet: View {
    let lockedOpen: Bool
    let unlock: () -> Void
    let choose: (ChatPrivacy) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            Text(ChatWords.startTitle).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
            Text(ChatWords.startNote).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            choice(.open, symbol: "bubble.left.and.bubble.right", enabled: true)
            choice(.locked, symbol: "lock.fill", enabled: lockedOpen)
            if !lockedOpen {
                Text(ChatWords.lockedNeedsUnlock).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                Button(action: unlock) {
                    Text(ChatWords.unlockKey).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            Spacer(minLength: 0)
        }
        .padding(Look.Space.gutter)
        .fingusGround()
    }

    private func choice(_ privacy: ChatPrivacy, symbol: String, enabled: Bool) -> some View {
        Button { choose(privacy) } label: {
            HStack(spacing: Look.Space.snug) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).frame(width: Look.Space.sizeTap)
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(privacy.title).fx(Look.Size.itemName, style: .headline)
                    Text(privacy.line).fx(Look.Size.itemMeta, style: .footnote).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(Look.Palette.fg)
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
            .fingusCard(radius: Look.Bubble.radiusCard)
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(BubblePressStyle())
        .disabled(!enabled)
        .accessibilityLabel("\(privacy.title). \(privacy.line)")
    }
}

// MARK: a chat

private struct ChatRoomPage: View {
    @ObservedObject var model: ChatRoomModel
    var back: () -> Void
    var unlock: () -> Void
    @FocusState private var focused: Bool
    @State private var showSafety = false
    @State private var showModels = false
    @State private var showRename = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header
            modelChip
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.phase == .ready || model.phase == .loading { composer }
        }
        .fingusGround()
        .sheet(isPresented: $showSafety) {
            SafetySheet(rows: model.safety, accept: { model.accept($0) })
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showModels) {
            ModelSheet(model: model) { showModels = false }
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showRename) {
            RenameSheet(current: model.title == ChatWords.newChat ? "" : model.title, save: { name in
                showRename = false
                Task { await model.rename(to: name) }
            }, cancel: { showRename = false })
            .presentationDetents([.medium])
        }
        .task { await model.load() }
        .onDisappear { model.leave() }
    }

    /// Which model answers, under the title, and a key to change it (the page's model pill). Hidden until the chat has said which.
    @ViewBuilder private var modelChip: some View {
        if model.phase != .locked, let name = model.modelName {
            Button {
                showModels = true
                Task { await model.loadChoices() }
            } label: {
                HStack(spacing: Look.Space.hair) {
                    Image(systemName: "cpu").font(.system(size: 11, weight: .bold))
                    Text(ChatWords.modelChip(name)).fx(Look.Size.pill, style: .footnote).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(Look.Palette.fg)
                .padding(.horizontal, Look.Space.snug).frame(minHeight: Look.Space.sizeTap)
                .background(Capsule().fill(Look.Palette.card))
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel(ChatWords.modelLabel(name))
            .accessibilityIdentifier("chat-model")
            .padding(.horizontal, Look.Space.gutter)
        }
    }

    private var header: some View {
        HStack(spacing: Look.Space.tight) {
            Button(action: back) {
                HStack(spacing: Look.Space.hair) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                    Text(ChatWords.listTitle).fx(Look.Size.tab, style: .subheadline)
                }
                .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
            }
            .accessibilityLabel(ChatWords.back)
            Spacer(minLength: 0)
            if model.phase == .ready && !model.safety.isEmpty {
                Button { showSafety = true } label: {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: model.keysChanged ? "exclamationmark.shield" : (model.allChecked ? "checkmark.shield" : "shield")).font(.system(size: 13, weight: .bold))
                        Text(ChatWords.safetyKey).fx(Look.Size.pill, style: .footnote)
                    }
                    .foregroundStyle(model.keysChanged ? Look.Palette.now : Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel(model.keysChanged ? ChatWords.safetyChanged : (model.allChecked ? ChatWords.safetyKey : ChatWords.safetyUnchecked))
            }
            if model.privacy == .locked {
                HStack(spacing: Look.Space.hair) {
                    Image(systemName: "lock.fill").font(.system(size: 12, weight: .bold))
                    Text("Locked").fx(Look.Size.pill, style: .footnote)
                }
                .foregroundStyle(Look.Palette.soft)
            }
            if model.phase == .ready && !model.isNew {
                Menu {
                    Button { showRename = true } label: { Label(ChatWords.renameKey, systemImage: "pencil") }
                    Button { showModels = true; Task { await model.loadChoices() } } label: { Label(ChatWords.modelTitle, systemImage: "cpu") }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.soft)
                        .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                }
                .accessibilityLabel(ChatWords.menu)
            }
        }
        .padding(.horizontal, Look.Space.gutter)
        .overlay {
            Text(model.phase == .locked ? ChatWords.lockedTitle : model.title).fx(Look.Size.itemName, style: .headline)
                .foregroundStyle(Look.Palette.fg).lineLimit(1).padding(.horizontal, Look.Space.titleReserve).allowsHitTesting(false)
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            VStack(spacing: Look.Space.snug) {
                Text(ChatWords.lockedShut).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                Button(action: unlock) {
                    Text(ChatWords.unlockKey).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .waitingForKeys:
            VStack(spacing: Look.Space.snug) {
                ProgressView()
                Text(model.waitingForApproval.map { ChatWords.waitingNote($0.name) } ?? ChatWords.waitingForKeys)
                    .fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).multilineTextAlignment(.center)
                Button { Task { await model.load() } } label: {
                    Text("Try again").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            .padding(.horizontal, Look.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            transcript
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: Look.Space.tight) {
                    if model.lines.isEmpty && model.isNew {
                        Text(model.privacy == .locked ? "This chat will be Locked. Say something to start." : "Say something to start.")
                            .fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).padding(.top, Look.Space.gutter)
                    }
                    ForEach(model.lines) { line in
                        ChatBubble(line: line)
                            .transition(.asymmetric(insertion: .scale(scale: 0.9, anchor: line.side == .mine ? .bottomTrailing : .bottomLeading).combined(with: .move(edge: .bottom)),
                                                    removal: .opacity))
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Look.Space.gutter)
                .padding(.vertical, Look.Space.snug)
                .animation(reduceMotion ? nil : pageSpring, value: model.lines)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: model.lines) { _ in
                withAnimation(reduceMotion ? nil : pageSpring) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    // MARK: the box and its keys

    private var composer: some View {
        VStack(spacing: Look.Space.hair) {
            if let stopped = model.stopped {
                ChatStoppedNote(stopped: stopped, key: {
                    if stopped.action == .unlock { unlock() } else { Task { await model.retry() } }
                })
            }
            HStack(alignment: .bottom, spacing: Look.Space.tight) {
                TextField("", text: $model.draft, prompt: Text(ChatWords.composerPrompt).foregroundColor(Look.Palette.inputText), axis: .vertical)
                    .fx(Look.Size.input, style: .body)
                    .foregroundStyle(Look.Palette.fg)
                    .lineLimit(1...5)
                    .focused($focused)
                    .padding(.leading, Look.Space.pad).padding(.vertical, Look.Space.snug)
                    .accessibilityIdentifier("chat-field")
                sendKey
                    .padding(.trailing, Look.Space.chip).padding(.bottom, Look.Space.chip)
            }
            .frame(minHeight: Look.Space.sizeInput)
            .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusInput, style: .continuous).fill(Look.Palette.input)
                .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowInput.alpha), radius: Look.Bubble.shadowInput.blur / 2, x: 0, y: Look.Bubble.shadowInput.y))
        }
        .padding(.horizontal, Look.Space.gutter).padding(.bottom, Look.Space.tight).padding(.top, Look.Space.hair)
        .animation(pageSpring, value: model.stopped)
    }

    /// Send, or, while a reply is being written and nothing is typed, Stop the reply (the page does the same with its one key).
    @ViewBuilder private var sendKey: some View {
        let typed = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if model.replying && !typed {
            Button { Task { await model.stopReply() } } label: {
                Image(systemName: "stop.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Look.Palette.ink)
                    .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap).background(Circle().fill(Look.Palette.accent))
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel(ChatWords.stop)
        } else {
            Button { Task { await model.send() } } label: {
                Image(systemName: "arrow.up").font(.system(size: 17, weight: .bold)).foregroundStyle(Look.Palette.ink)
                    .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap).background(Circle().fill(Look.Palette.accent))
                    .opacity(typed && !model.sending ? 1 : 0.4)
            }
            .buttonStyle(BubblePressStyle())
            .disabled(!typed || model.sending)
            .accessibilityLabel(ChatWords.send)
        }
    }
}

// MARK: the model and the name

/// The models this chat may use, one tap to switch; the one in use is marked with a check and its words, not colour alone.
private struct ModelSheet: View {
    @ObservedObject var model: ChatRoomModel
    var done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.tight) {
                Text(ChatWords.modelTitle).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                if model.privacy == .locked {
                    Text(ChatWords.modelNote).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                }
                if model.modelChoices.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Look.Space.section)
                }
                ForEach(model.modelChoices, id: \.self) { name in
                    let current = name == model.modelName
                    Button {
                        Task { await model.chooseModel(name); done() }
                    } label: {
                        HStack(spacing: Look.Space.snug) {
                            VStack(alignment: .leading, spacing: Look.Space.hair) {
                                Text(ChatModelPick.shown(name)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                                Text(ChatModelPick.note(name)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                            }
                            Spacer(minLength: 0)
                            if current { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Look.Palette.fg) }
                        }
                        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                        .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
                        .fingusCard(radius: Look.Bubble.radiusRow)
                    }
                    .buttonStyle(BubblePressStyle())
                    .accessibilityLabel(ChatModelPick.shown(name) + ". " + ChatModelPick.note(name) + (current ? ". In use" : ""))
                    .accessibilityAddTraits(current ? .isSelected : [])
                }
                Button(action: done) {
                    Text("Done").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
            }
            .padding(Look.Space.gutter)
        }
        .fingusGround()
    }
}

/// A name for the chat, kept as hers: the PC stops naming it. Empty lets it name the chat again.
private struct RenameSheet: View {
    @State var text: String
    let save: (String) -> Void
    let cancel: () -> Void

    init(current: String, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        _text = State(initialValue: current)
        self.save = save
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            Text(ChatWords.renameTitle).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
            TextField("", text: $text, prompt: Text(ChatWords.renamePrompt).foregroundColor(Look.Palette.inputText))
                .fx(Look.Size.input, style: .body).foregroundStyle(Look.Palette.fg)
                .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeControl)
                .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).fill(Look.Palette.input))
                .accessibilityIdentifier("chat-rename-field")
            HStack(spacing: Look.Space.tight) {
                Button { save(text) } label: {
                    Text(text.trimmingCharacters(in: .whitespaces).isEmpty ? ChatWords.renameClear : ChatWords.renameSave)
                        .fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
                Button(action: cancel) {
                    Text("Cancel").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.soft)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Look.Space.gutter)
        .fingusGround()
    }
}

/// This phone is waiting for a device she already uses to approve it: its own fruit name, and where to approve it.
struct ChatWaitingNote: View {
    let name: String?
    var code: String? = nil
    let check: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            Text(ChatWords.waitingTitle).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
            Text(ChatWords.waitingNote(name)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            if let code { Text(ChatWords.waitingCode(code)).font(.system(.title3, design: .monospaced)).foregroundStyle(Look.Palette.fg).textSelection(.enabled) }
            FingusKey(title: ChatWords.waitingCheck, action: check)
        }
        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fingusCard(radius: Look.Bubble.radiusCard)
        .accessibilityElement(children: .contain)
    }
}

// MARK: the safety code

private struct SafetySheet: View {
    let rows: [ChatSafetyRow]
    let accept: (ChatSafetyRow) -> Void

    private func shown(_ name: String) -> String {
        switch name {
        case "@pc": return "Your PC"
        case "@fingoid": return "Fingoid"
        default: return ChatListing.shownName(ChatMember(kind: "person", name: name, nick: nil, model: nil))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                Text(ChatWords.safetyTitle).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                Text(ChatWords.safetyNote).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: Look.Space.hair) {
                        Text(shown(row.name)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                        Text(row.code).font(.system(.title3, design: .monospaced)).foregroundStyle(Look.Palette.fg).textSelection(.enabled)
                        if row.status != .checked {
                            Text(row.changed ? ChatWords.safetyChanged : ChatWords.safetyUnchecked).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(row.changed ? Look.Palette.now : Look.Palette.soft)
                            Button { accept(row) } label: {
                                Text(ChatWords.safetyAccept).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                                    .background(Capsule().fill(Look.Palette.accent))
                            }
                            .buttonStyle(BubblePressStyle())
                        }
                    }
                    .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fingusCard(radius: Look.Bubble.radiusCard)
                }
            }
            .padding(Look.Space.gutter)
        }
        .fingusGround()
    }
}

// MARK: a line

private struct ChatBubble: View {
    let line: ChatLine

    var body: some View {
        switch line.side {
        case .note:
            Text(line.text).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                .frame(maxWidth: .infinity).multilineTextAlignment(.center).padding(.vertical, Look.Space.hair)
        case .mine, .theirs:
            let mine = line.side == .mine
            HStack(spacing: 0) {
                if mine { Spacer(minLength: 56) }
                VStack(alignment: mine ? .trailing : .leading, spacing: Look.Space.hair) {
                    if let speaker = line.speaker {
                        Text(speaker).fx(Look.Size.itemMeta, style: .caption1).foregroundStyle(Look.Palette.soft)
                    }
                    words(mine: mine)
                }
                if !mine { Spacer(minLength: 56) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel((mine ? "You: " : (line.speaker.map { $0 + ": " } ?? "")) + (line.text.isEmpty ? "writing" : line.text))
        }
    }

    @ViewBuilder private func words(mine: Bool) -> some View {
        let text = Text(line.text.isEmpty ? "\u{2026}" : line.text).fx(Look.Size.input, style: .body)
        if mine {
            text.foregroundStyle(Look.Palette.ink)
                .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                .bubble(nil, radius: Look.Bubble.radiusItem)
        } else {
            Group {
                if line.unreadable { text.italic().foregroundStyle(Look.Palette.soft) } else { text.foregroundStyle(Look.Palette.fg) }
            }
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .fingusCard(radius: Look.Bubble.radiusItem)
        }
    }
}

// MARK: something stopped

/// The one shape, drawn quietly: what was being done, which step stopped and what can be done now, with a key that does it.
private struct ChatStoppedNote: View {
    let stopped: ChatStopped
    let key: () -> Void
    @State private var asking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            Text(stopped.text).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            HStack(spacing: Look.Space.tight) {
                FingusKey(title: stopped.key, action: key)
                // Doctor is a part of the PC; Chat only runs with one, but the key follows the same rule as every failure line
                if ConnectionStatus.whyOffered(hasAddress: AppInfo.address != nil) {
                    FingusKey(title: "Find out why", prominent: false) { asking = true }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $asking) { FindOutWhySheet(failure: stopped.diagnosis) { asking = false } }
    }
}

/// The old keys cannot open some chats, so they cannot be brought to the newer ones: said plainly, with two keys that each say what tapping does.
/// Nothing is changed until the first is tapped.
private struct ChatRenewalChoiceNote: View {
    let rooms: Int
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.tight) {
            Text(ChatWords.renewalChoice(rooms)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            HStack(spacing: Look.Space.tight) {
                Button(action: decline) {
                    Text(ChatWords.renewalKeep).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
                Button(action: accept) {
                    Text(ChatWords.renewalMoveOn).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.soft)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                }
                .buttonStyle(BubblePressStyle())
            }
        }
    }
}

/// Chat with no PC set up: the tab is still there, and says why it is empty and what to do (a hidden tab told her nothing, 2026-10-17).
struct ChatNeedsPCScreen: View {
    /// Back to the calendar.
    var back: () -> Void
    /// Opens the page where the PC's address is set.
    var connect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text("Today").fx(Look.Size.tab, style: .subheadline)
                    }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel("Back to today")
                Spacer()
            }
            .padding(.horizontal, Look.Space.gutter)
            VStack(spacing: Look.Space.snug) {
                Text(ChatWords.needsPC).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    .multilineTextAlignment(.center)
                Button(action: connect) {
                    Text(ChatWords.connectPC).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            .padding(Look.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .fingusGround()
    }
}
