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
    static let waitingForKeys = "This chat isn't ready on this phone yet. Your PC is sharing it."
    static let lockedTitle = "Locked chat"

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
    var text: String { "\(doing) stopped at \(step). \(next)" }
}

enum ChatStep {
    static let reaching = "reaching Aero"
    static let signingIn = "signing in"
    static let lock = "the lock"
    static let address = "finding Aero's address"
    static let phoneKeys = "reading it on this phone"
    static let answer = "Aero's answer"
}

enum ChatStopWords {
    /// What was being done, as a phrase that goes before "stopped at".
    static let loadingList = "Showing your chats"
    static let opening = "Opening this chat"
    static let sending = "Sending your message"
    static let starting = "Starting the chat"
    static let stoppingReply = "Stopping the reply"
    static let checkingLock = "Checking the lock"

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
            case .server:
                return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
            case .unreadable:
                return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
            }
        }
        if error is URLError {
            return ChatStopped(doing: doing, step: ChatStep.reaching, next: "Check your connection, then try again.", key: "Try again", action: .retry)
        }
        if error is ChatCryptoError || error is ChatSessionError {
            return ChatStopped(doing: doing, step: ChatStep.phoneKeys, next: "Your PC may still be sharing the keys. Try again in a moment.", key: "Try again", action: .retry)
        }
        return ChatStopped(doing: doing, step: ChatStep.answer, next: "Try again.", key: "Try again", action: .retry)
    }
}
