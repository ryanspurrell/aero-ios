import Foundation

// Devices: this person's devices for chats, as Aero's Devices place under You shows them (messages.js, `chatDevices`): each one's name, kind and
// date added; a waiting one can be approved from a device she already uses, any can be renamed, and any other can be removed. Built on the
// Messages routes (devices/mine.json, approve, remove, rename); the signing is done here with this phone's own key, which never leaves it.
// Specified in Systems/DeviceApproval.lean: only an approval signed by a trusted device makes a device trusted; removal stops any key being
// sealed to it afterwards; the last trusted device cannot be removed; a name is only a label.

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

/// The plain rules of the Devices screen: what is listed in which order, what each row says, and what may be done to it.
enum DeviceListing {
    /// A waiting device first (it needs something done), then the rest as they were added.
    static func order(_ rows: [DeviceRow]) -> [DeviceRow] {
        rows.enumerated().sorted { a, b in
            if a.element.trusted != b.element.trusted { return !a.element.trusted }
            let x = a.element.added ?? 0, y = b.element.added ?? 0
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    static func title(_ row: DeviceRow, this: String?) -> String {
        row.shownName + (row.device == this ? " (this phone)" : "")
    }

    /// "Waiting for approval", or what kind of device it is and when it was added.
    static func note(_ row: DeviceRow, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String {
        if !row.trusted { return DevicesWords.waiting }
        var parts: [String] = []
        if let kind = row.kind, !kind.isEmpty { parts.append(kind) }
        if let added = row.added, added > 0 { parts.append(DevicesWords.added(day(Date(timeIntervalSince1970: added), calendar: calendar, locale: locale))) }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func day(_ date: Date, calendar: Calendar, locale: Locale) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd y")
        return f.string(from: date)
    }

    static func iAmTrusted(_ rows: [DeviceRow], this: String?) -> Bool {
        guard let this else { return false }
        return rows.contains { $0.device == this && $0.trusted }
    }

    /// Approving needs a trusted device of mine, and a waiting row that is not this phone (a phone cannot approve itself).
    static func canApprove(_ row: DeviceRow, rows: [DeviceRow], this: String?) -> Bool {
        !row.trusted && row.device != this && iAmTrusted(rows, this: this)
    }

    /// Why a row cannot be removed from here, in words; nil when it can. A device that is waiting cannot remove anything. This phone is not
    /// removed from itself: its chats would lose their keys under it. (The last approved device always stays, which Aero enforces; from here it
    /// can only be this phone, since removing needs an approved phone and it is the only one left.)
    static func removalBlocked(_ row: DeviceRow, rows: [DeviceRow], this: String?) -> String? {
        if !iAmTrusted(rows, this: this) { return DevicesWords.removeNeedsApproval }
        if row.device == this { return DevicesWords.removeFromAnother }
        return nil
    }
}

enum DevicesWords {
    static let title = "Devices"
    static let youRow = "Devices"
    static let youDetail = "Approve, rename or remove"
    static let waiting = "Waiting for approval"
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
    static let removeNote = "It won't get new keys for your chats. You can approve it again later"
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
    @Published private(set) var rows: [DeviceRow] = []
    @Published private(set) var loaded = false
    @Published private(set) var stopped: ChatStopped?
    /// What was just done, in a few words, until the next change.
    @Published private(set) var notice: String?
    @Published private(set) var busy = false
    /// The device whose removal was asked for once; a second tap on the same one removes it. It is forgotten after `armSeconds`.
    @Published private(set) var armed: String?

    let session: ChatSession
    /// Aero's clock minus this phone's, from the last list: a signature is good only for a few minutes of Aero's time (600 seconds in the store).
    private(set) var offset: Double = 0
    private var armTask: Task<Void, Never>?
    /// The page arms a removal for four seconds (phone_design_conventions.md 6.1); the same here.
    static let armSeconds: Double = 4

    init(session: ChatSession) {
        self.session = session
    }

    var thisDevice: String? { DemoMode.devicesDemo ? DemoMode.thisDeviceID : session.deviceID }
    var ordered: [DeviceRow] { DeviceListing.order(rows) }
    var iAmTrusted: Bool { DeviceListing.iAmTrusted(rows, this: thisDevice) }
    /// Set while this phone itself is waiting to be approved.
    var thisPhoneWaiting: DeviceRow? { rows.first { $0.device == thisDevice && !$0.trusted } }

    /// Aero's time now, in whole seconds, for a signature.
    func timestamp(now: Date = Date()) -> Int { Int((now.timeIntervalSince1970 + offset).rounded(.down)) }

    func load() async {
        if DemoMode.devicesDemo { rows = DemoMode.deviceRows; loaded = true; return }
        stopped = nil
        let g = session.generation
        do {
            // this phone is a device first, so that it is in the list and `thisDevice` is known
            _ = try await session.ensureDevice()
            let got = try await session.api.devicesMine()
            guard g == session.generation else { return }
            offset = got.now - Date().timeIntervalSince1970
            rows = got.devices
            loaded = true
            await session.refreshTrust()
        } catch is ChatStale {
            return
        } catch {
            session.note(error)
            stopped = ChatStopWords.make(doing: DevicesWords.listing, error: error)
        }
    }

    func approve(_ row: DeviceRow) async {
        guard DeviceListing.canApprove(row, rows: rows, this: thisDevice), !busy else { return }
        await act(DevicesWords.approving, done: DevicesWords.approved) { device in
            let ts = self.timestamp()
            let text = DeviceSigning.approvalText(person: self.session.person, device: row.device, ecdh: row.ecdh, sign: row.sign, ts: ts)
            try await self.session.api.approveDevice(.init(by: device.id, device: row.device, ts: ts, proof: try DeviceSigning.proof(text, by: device),
                                                           code: DeviceCode.code(ecdh: row.ecdh, sign: row.sign)))
        }
    }

    /// The first tap arms the removal, the second (on the same device, within `armSeconds`) does it.
    func removeTapped(_ row: DeviceRow) async {
        guard DeviceListing.removalBlocked(row, rows: rows, this: thisDevice) == nil, !busy else { return }
        if armed != row.device {
            armed = row.device
            armTask?.cancel()
            armTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(DevicesModel.armSeconds * 1_000_000_000))
                if !Task.isCancelled { self?.armed = nil }
            }
            return
        }
        armTask?.cancel()
        armed = nil
        await act(DevicesWords.removing, done: DevicesWords.removed) { device in
            let ts = self.timestamp()
            let text = DeviceSigning.removalText(person: self.session.person, device: row.device, ts: ts)
            try await self.session.api.removeDeviceSigned(.init(by: device.id, device: row.device, ts: ts, proof: try DeviceSigning.proof(text, by: device)))
        }
    }

    func rename(_ row: DeviceRow, to name: String) async {
        let words = name.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !words.isEmpty, words != row.name, !busy else { return }
        await act(DevicesWords.renaming, done: DevicesWords.renamed) { _ in
            _ = try await self.session.api.renameDevice(row.device, to: words)
        }
    }

    private func act(_ doing: String, done: String, _ work: @escaping (ChatDevice) async throws -> Void) async {
        busy = true
        stopped = nil
        notice = nil
        let g = session.generation
        defer { busy = false }
        do {
            let device = try await session.ensureDevice()
            try await work(device)
            guard g == session.generation else { return }
            notice = done
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
        rows = []; loaded = false; stopped = nil; notice = nil; armed = nil
    }
}
