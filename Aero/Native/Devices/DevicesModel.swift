import Foundation

// Devices: this person's devices as Aero's Devices place under You shows them: one row per device with its parts inside (sign-ins, chat keys
// trusted or waiting, the file key). A waiting device can be approved from a device she already uses, matching the code on both screens; any can
// be renamed; two that are one can be merged after she sees why; any other can be removed, with every part, after she confirms. Built on the
// PC's unified `one-devices` routes (aero_web.py) and, for the chat keys, Messages' signed approve and remove (devices/approve, devices/remove):
// the signing is done here with this phone's own key, which never leaves it.
// Specified in Systems/DeviceApproval.lean (only an approval signed by a trusted device makes a device trusted; removal stops any key being
// sealed to it; the last trusted device cannot be removed; a name is only a label), Systems/DeviceApprovalCode.lean, Systems/OneDevice.lean and
// Systems/OneDeviceRemoval.lean.

/// What the approving or removing device signs. Fixed strings, the same as `fingus_messages_store.approval_text` / `removal_text`
/// (AeroTests/DeviceSigningTests carries the server's own output for fixed inputs).
enum DeviceSigning {
    /// The new device's keys and their code, for this person, at this time (the store's `approval_text`).
    static func approvalText(person: String, device: String, ecdh: String, sign: String, ts: Int) -> String {
        "approve|\(person)|\(device)|\(ecdh)|\(sign)|\(ts)|\(DeviceCode.code(ecdh: ecdh, sign: sign))"
    }

    static func removalText(person: String, device: String, ts: Int) -> String {
        "remove|\(person)|\(device)|\(ts)"
    }

    /// The signature of `text` by this device's signing key: ECDSA P-256 over SHA-256, the 64 bytes r then s, base64url without padding.
    static func proof(_ text: String, by device: ChatDevice) throws -> String {
        ChatBase64.encode(try device.signRaw(Data(text.utf8)))
    }
}

enum DevicesWords {
    static let title = "Devices"
    static let youRow = "Devices"
    static let youDetail = "Approve, rename or remove"
    static let waiting = "Waiting for approval"
    static let signedIn = "Signed in"
    static let chatKeys = "Chat keys"
    static let fileKey = "Files"
    static let removingState = "Removing\u{2026}"
    static let removeNotNow = "This device can't be removed now."
    static let needsPC = "Your devices are kept on your PC. Connect it to see them."
    static let empty = "No devices yet."
    static let approve = "Approve"
    static let codeQuestion = "Does this match the other screen?"
    static let codeMatches = "It matches"
    static func approveNote(_ name: String) -> String { "Lets \(name) read your chats" }
    static func added(_ day: String) -> String { "Added \(day)" }
    static let namePlaceholder = "A name for this device"
    static let keepName = "Keep this name"
    static func remove(_ name: String) -> String { "Remove \(name)" }
    static let removeSure = "Tap again to remove"
    static func removeHas(_ has: String) -> String { "Removes \(has). Chats and files locked to it stay closed to it" }
    static let removeConfirmFirst = "You will be asked to confirm"
    static let removeCarryOn = "Tap to carry on"
    static let removeCarryOnAgain = "Tap again to carry on"
    static func removeAgain(_ why: String) -> String { "\(why). Tap to try again" }
    static func removingName(_ name: String) -> String { "Removing\u{2026} \(name)" }
    static func isItYours(_ name: String) -> String { "Is \(name) yours?" }
    static let whyNotYet = "Why it is not removed yet"
    static let whatItIs = "What it is"
    static let confirmNotYours = "Confirm it's not yours"
    static func confirmNote(_ name: String) -> String { "Then \(name) and everything of it is removed" }
    static func lastInUse(_ when: String) -> String { "Last in use: \(when)" }
    static let never = "never"
    static let keepIt = "Keep it"
    static let mergeWith = "Merge with another device"
    static let mergeIfSame = "If it is the same device"
    static let mayBeSame = "These may be the same device"
    static func mergeTitle(_ a: String, _ b: String) -> String { "Merge \(a) and \(b)" }
    static let becomeOne = "These become one device"
    static func mergeAs(_ name: String) -> String { "Merge as \(name)" }
    static let mergeKeeps = "Keeps every sign-in and key of both"
    static let merged = "Merged"
    static let merging = "Merging the devices"
    static let evidence = "What was seen"
    static func seen(_ when: String) -> String { "Last seen \(when)" }
    static let approvedWord = "Approved"
    static let approvedByPC = "Approved by the PC"
    static let codeNotThisDevices = "That code is not this device's."
    static func codeIs(_ code: String) -> String { "Code \(code)" }
    static func sameCode(_ name: String) -> String { "Is \(name) showing the same code?" }
    static let waitingNeedsTrusted = "Approve it from a device you already use"
    static let removeNeedsApproval = "This phone has to be approved before it can remove a device."
    static let removeFromAnother = "To remove this phone, do it from another device."
    static let approved = "Approved"
    static let renamed = "Renamed"
    static let removed = "Removed"
    static let checkAgain = "Check again"
    static let back = "Back to You"
    static let approving = "Approving the device"
    static let removing = "Removing the device"
    static let renaming = "Renaming the device"
    static let listing = "Showing your devices"
}

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var devices: [OneDevice] = []
    @Published private(set) var maybeSame: [OneMaybeSame] = []
    @Published private(set) var loaded = false
    @Published private(set) var stopped: ChatStopped?
    /// What was just done, in a few words, until the next change.
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    /// The device whose removal was asked for once; a second tap on the same one removes it. It is forgotten after `armSeconds`.
    @Published private(set) var armed: String?
    /// A removal the PC will not do in one step: shown with why and the evidence until she confirms it is not hers, or leaves it.
    @Published private(set) var asking: OneRemovalAsk?
    /// What is being done now ("Removing the device"), until it is done.
    @Published private(set) var working: String?

    let session: ChatSession
    /// The PC's clock minus this phone's, from the last list: a signature is good only for a few minutes of the PC's time (600 seconds in the store).
    private(set) var offset: Double = 0
    private var armTask: Task<Void, Never>?
    /// The page arms a removal for four seconds (phone_design_conventions.md 6.1); the same here.
    static let armSeconds: Double = 4

    init(session: ChatSession) {
        self.session = session
    }

    /// This phone's own chat key, which is what marks "this device" in the list.
    var thisDevice: String? { DemoMode.devicesDemo ? DemoMode.thisDeviceID : session.deviceID }
    var iAmTrusted: Bool { OneDeviceListing.iAmTrusted(devices, thisChat: thisDevice) }
    /// Set while this phone itself is waiting to be approved: its chat key and its code.
    var thisPhoneWaiting: OneChatKey? { devices.flatMap { $0.parts.chat }.first { $0.device == thisDevice && !$0.trusted } }

    /// The PC's time now, in whole seconds, for a signature.
    func timestamp(now: Date = Date()) -> Int { Int((now.timeIntervalSince1970 + offset).rounded(.down)) }

    func device(_ id: String) -> OneDevice? { devices.first { $0.id == id } }

    func load() async {
        if DemoMode.devicesDemo {
            devices = DemoMode.oneDevices; maybeSame = DemoMode.maybeSame; asking = DemoMode.removalAsk; loaded = true
            return
        }
        stopped = nil
        let g = session.generation
        do {
            // this phone is a device first, so that its chat key is in the list and `thisDevice` is known
            _ = try await session.ensureDevice()
            let got = try await session.api.oneDevices(chat: session.deviceID)
            guard g == session.generation else { return }
            offset = got.now - Date().timeIntervalSince1970
            devices = got.devices
            maybeSame = got.maybeSame
            loaded = true
            if let ask = asking, let now = device(ask.device.id) { asking = OneRemovalAsk(device: now, reasons: ask.reasons, info: ask.info) } else { asking = nil }
            await session.refreshTrust()
        } catch is ChatStale {
            return
        } catch {
            session.note(error)
            stopped = ChatStopWords.make(doing: DevicesWords.listing, error: error)
        }
    }

    /// Approve every waiting chat key of the device, each signed with this phone's key and carrying the code she saw on both screens (the PC
    /// checks it is those keys' code). A key whose code the PC lists differently from the one made here is not approved.
    func approve(_ d: OneDevice) async {
        let keys = OneDeviceListing.approvable(d, devices: devices, thisChat: thisDevice)
        guard !keys.isEmpty, !busy else { return }
        await act(DevicesWords.approving) { device in
            for k in keys {
                guard OneDeviceListing.shownCode(k) != nil else { throw ChatAPI.Failure.server(DevicesWords.codeNotThisDevices) }
                let ts = self.timestamp()
                let code = DeviceCode.code(ecdh: k.ecdh, sign: k.sign)
                let text = DeviceSigning.approvalText(person: self.session.person, device: k.device, ecdh: k.ecdh, sign: k.sign, ts: ts)
                try await self.session.api.approveDevice(.init(by: device.id, device: k.device, ts: ts, proof: try DeviceSigning.proof(text, by: device), code: code))
            }
            return DevicesWords.approved
        }
    }

    /// The first tap arms the removal, the second (on the same device, within `armSeconds`) does it.
    func removeTapped(_ d: OneDevice) async {
        guard OneDeviceListing.removalBlocked(d, devices: devices, thisChat: thisDevice) == nil, !busy else { return }
        if armed != d.id {
            armed = d.id
            armTask?.cancel()
            armTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(DevicesModel.armSeconds * 1_000_000_000))
                if !Task.isCancelled { self?.armed = nil }
            }
            return
        }
        armTask?.cancel()
        armed = nil
        await remove(d, ack: nil)
    }

    /// "Confirm it's not yours": the evidence she was shown goes back as it came, and the removal goes on.
    func confirmNotYours() async {
        guard let ask = asking, !busy else { return }
        asking = nil
        await remove(ask.device, ack: ask.info)
    }

    func leaveAsk() { asking = nil }

    /// The PC writes "removing" on the device and stops sealing to its chat keys; this phone then forgets those chat keys (a device she trusts
    /// must sign that); the PC then removes the rest, step by step, each recorded. A step that stops is said, and asking again carries on.
    private func remove(_ d: OneDevice, ack: OneInfo?) async {
        await act(DevicesWords.removing) { device in
            var result = try await self.session.api.oneRemove(d.id, ack: ack)
            if case .confirm(let reasons, let info) = result {
                self.asking = OneRemovalAsk(device: d, reasons: reasons, info: info)
                return nil
            }
            if case .progress(let p) = result, !p.gone, !d.parts.chat.isEmpty {
                for k in d.parts.chat where k.device != device.id {
                    let ts = self.timestamp()
                    let text = DeviceSigning.removalText(person: self.session.person, device: k.device, ts: ts)
                    try await self.session.api.removeDeviceSigned(.init(by: device.id, device: k.device, ts: ts, proof: try DeviceSigning.proof(text, by: device)))
                }
                result = try await self.session.api.oneRemove(d.id)
            }
            guard case .progress(let p) = result else { return nil }
            return p.gone ? DevicesWords.removed : DevicesWords.removingState + (p.stuck.map { " " + $0 } ?? "")
        }
    }

    func rename(_ d: OneDevice, to name: String) async {
        let words = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !words.isEmpty, words != d.name, !busy else { return }
        await act(DevicesWords.renaming) { _ in
            _ = try await self.session.api.oneRename(d.id, to: words)
            return DevicesWords.renamed
        }
    }

    /// Two rows that are one device, after she has seen both and why: `gone`'s parts join `keep`.
    func merge(keep: OneDevice, gone: OneDevice) async {
        guard !busy else { return }
        await act(DevicesWords.merging) { _ in
            try await self.session.api.oneMerge(keep: keep.id, gone: gone.id)
            return DevicesWords.merged
        }
    }

    /// Runs one change as the signed-in device, then reads the list again. `work` returns what to say it did, or nil to say nothing.
    private func act(_ doing: String, _ work: @escaping (ChatDevice) async throws -> String?) async {
        busy = true
        working = doing
        stopped = nil
        notice = nil
        let g = session.generation
        defer { busy = false; working = nil }
        do {
            let device = try await session.ensureDevice()
            let said = try await work(device)
            guard g == session.generation else { return }
            notice = said
            await load()
        } catch is ChatStale {
            return
        } catch {
            session.note(error)
            stopped = ChatStopWords.make(doing: doing, error: error)
        }
    }

    func clear() {
        armTask?.cancel()
        devices = []; maybeSame = []; loaded = false; stopped = nil; notice = nil; armed = nil; asking = nil
    }
}
