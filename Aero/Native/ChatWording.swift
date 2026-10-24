import Foundation

/// The words of Chat, in one place (projects/aero/wording_conventions.md: plain and personal, sentence case, a key says what tapping it does;
/// "How Fingus speaks when something stops": what was being done, which step stopped, and what can be done now). No emojis.
enum ChatWords {
    static let tab = "Chat"
    static let listTitle = "Chats"
    static let newChat = "New chat"
    static let empty = "No chats yet. Start one with New chat."
    static let composerPrompt = "Message"
    static let send = "Send"
    static let stop = "Stop the reply"
    static let back = "Back to chats"
    static let startTitle = "Who can see this chat"
    static let startNote = "You choose this first. It can't be changed after the chat has started."
    static let lockedNeedsUnlock = "Locked chats open once Aero has unlocked with Face ID."
    static let unlockKey = "Unlock in Aero"
    static let lockedShut = "This chat is Locked."
    static let keysRenewed = "This phone's chat keys were renewed. Older chats may take a moment to open again."
    static let renewalStopped = "Your chats are still open on this phone as before. The newer, safer keys can't open all of them yet, so nothing was changed. This is tried again next time."
    /// The old keys on this phone cannot open some chats, so they cannot be brought to the newer keys. Said before anything is changed.
    static func renewalChoice(_ rooms: Int) -> String {
        let which = rooms == 1 ? "1 older chat" : rooms > 1 ? "\(rooms) older chats" : "Some older chats"
        return "Your newer, safer keys are ready. \(which) can't be opened with the keys this phone has now, so \(rooms == 1 ? "it" : "they") can't be brought across and would stay closed. Everything else opens as before."
    }
    static let renewalMoveOn = "Move on, leave them closed"
    static let renewalKeep = "Keep things as they are"
    static let renewalDeclined = "Nothing was changed, and your chats are open on this phone as before. You can choose again next time."
    static let safetyUnchecked = "You haven't compared these numbers yet."
    static let safetyKey = "Safety code"
    static let safetyTitle = "Safety code"
    static let safetyNote = "Read these numbers to the person, or have them read theirs to you. If they are the same on both phones, the keys are the right ones."
    static let safetyChanged = "These numbers are different from the last time you looked."
    static let safetyAccept = "They match"
    static let waitingForKeys = "This chat isn't ready on this phone yet. Your PC is sharing it."
    static let waitingTitle = "Waiting for approval"
    static let waitingCheck = "Check again"
    /// This phone is a new device and a device she already uses has not approved it, so no chat key is sealed to it yet. Says its own fruit name
    /// and where to approve it (the page says the same under Devices).
    static func waitingNote(_ name: String?) -> String {
        "\(name ?? "This phone") is waiting for you to approve it. On a device you already use, open You, then Devices. Tap \(name ?? "this phone"), then Approve."
    }
    static func waitingToSend(_ name: String?) -> String {
        "\(name ?? "This phone") isn't approved yet, so it can't send. Approve it from a device you already use, then check again."
    }
    static let modelTitle = "Model"
    static func modelChip(_ model: String) -> String { ChatModelPick.shown(model) }
    static func modelLabel(_ model: String) -> String { "Model, \(ChatModelPick.shown(model)). Change" }
    static let modelNote = "A Locked chat can only use models that run on your PC."
    static let renameKey = "Rename chat"
    static let renameTitle = "Rename chat"
    static let renamePrompt = "A name for this chat"
    static let renameSave = "Keep this name"
    static let renameClear = "Let Fingus name it"
    static let menu = "Chat menu"

    static let lockedTitle = "Locked chat"
    static let needsPC = "Chats live on your PC. Connect it to chat here."
    static let connectPC = "Connect your PC"
    /// Words for what this app calls itself in Aero's list of chat devices ("iPhone (browser)" is the page's, "iPhone (Aero app)" this app's).
    static let deviceLabel = "iPhone (Aero app)"

    /// This phone was refused as a chat device because the most is already there. Aero says the same words to the page.
    static func devicesFull(_ count: Int) -> String {
        "This phone can't be added: you have \(count > 0 ? "\(count) devices" : "too many devices"). Remove one in Devices."
    }

    /// This phone's device was removed from the person's list; it makes new keys the next time.
    static let deviceRemoved = "This phone was removed from your devices, so it needs new keys. Try again."

    static func rowNote(_ unread: String?, locked: Bool) -> String? {
        [locked ? "Locked" : nil, unread].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Something stopped, in the one shape: what was being done, which step stopped, what can be done now, and a key that does it.
struct ChatStopped: Equatable {
    enum Action: Equatable { case retry, unlock }
    var doing: String
    var step: String
    var next: String
    var key: String
    var action: Action
    /// Said as it is instead of in the shape, for a stop that is the whole of what the person needs ("This phone can't be added: ...").
    var words: String? = nil
    /// What Aero said, when it said something in words of its own (a refusal's sentence); shown so the line is not only "Aero's answer".
    var said: String? = nil
    /// Doctor's id for this kind of failure (fingus_core_doctor_failures.json), for the Find out why key.
    var diagnosis = "other"
    var text: String {
        if let words { return words }
        let aero = said.map { " Aero said \u{201C}\($0)\u{201D}." } ?? ""
        return "\(doing) stopped at \(step).\(aero) \(next)"
    }
}

enum ChatStep {
    static let reaching = "reaching Aero"
    static let signingIn = "signing in"
    static let lock = "the lock"
    static let address = "finding Aero's address"
    static let phoneKeys = "reading it on this phone"
    static let answer = "Aero's answer"
    static let devices = "adding this phone"
}

enum ChatStopWords {
    /// What was being done, as a phrase that goes before "stopped at".
    static let loadingList = "Showing your chats"
    static let opening = "Opening this chat"
    static let sending = "Sending your message"
    static let starting = "Starting the chat"
    static let stoppingReply = "Stopping the reply"
    static let checkingLock = "Checking the lock"
    static let listingModels = "Listing the models"
    static let changingModel = "Changing the model"
    static let renaming = "Renaming the chat"

    /// The one shape for a failure of `error` while `doing` something. Anything not recognised is said as Aero's answer, never as a cause the
    /// app made up.
    static func make(doing: String, error: Error) -> ChatStopped {
        if let f = error as? ChatAPI.Failure {
            switch f {
            case .noAddress:
                return ChatStopped(doing: doing, step: ChatStep.address, next: "Connect your PC from the menu.", key: "Try again", action: .retry)
            case .notSignedIn:
                return ChatStopped(doing: doing, step: ChatStep.signingIn, next: "Open Aero to sign in, then try again.", key: "Try again", action: .retry)
            case .locked:
                return ChatStopped(doing: doing, step: ChatStep.lock, next: "Unlock in Aero, then try again.", key: ChatWords.unlockKey, action: .unlock)
            case .devicesFull(let count):
                return ChatStopped(doing: doing, step: ChatStep.devices, next: "Remove one in Devices, then try again.", key: "Try again", action: .retry,
                                   words: ChatWords.devicesFull(count))
            case .deviceRemoved:
                return ChatStopped(doing: doing, step: ChatStep.devices, next: "This phone was removed from your devices, so it needs new keys. Try again.", key: "Try again", action: .retry,
                                   words: ChatWords.deviceRemoved)
            case .server(let words):
                // the generic words are the app's own, not Aero's
                let aero = words == "That didn't work. Try again." ? nil : words
                return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry, said: aero)
            case .notCovered:
                return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
            case .notAero:
                return ChatStopped(doing: doing, step: ChatStep.reaching, next: "Check your connection, then try again.", key: "Try again", action: .retry,
                                   diagnosis: "pc_unreachable")
            case .unreadable:
                return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
            }
        }
        if error is URLError {
            return ChatStopped(doing: doing, step: ChatStep.reaching, next: "Check your connection, then try again.", key: "Try again", action: .retry,
                               diagnosis: "pc_unreachable")
        }
        if error is ChatKeyError {
            return ChatStopped(doing: doing, step: ChatStep.phoneKeys, next: "Unlock the phone, then try again. Nothing was changed.", key: "Try again", action: .retry)
        }
        if error is ChatCryptoError || error is ChatSessionError {
            return ChatStopped(doing: doing, step: ChatStep.phoneKeys, next: "Your PC may still be sharing the keys. Try again in a moment.", key: "Try again", action: .retry)
        }
        return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
    }
}
