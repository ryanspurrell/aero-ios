import SwiftUI

// The Devices screen, a page that comes in from You: this phone's own state first (waiting for approval, with its fruit name and its code), then
// one row per device with what it has (signed in, chat keys, files). A tap opens one: its parts, approve it (matching the code on both screens),
// give it a name, merge it with another it is the same as, remove it. Every action is a visible key; removing asks twice, as the page does, and a
// device used lately (or never matched to one she uses) asks her to confirm it is not hers, showing why. Look is Aero's (Tokens.swift, FingusUI.swift).

struct DevicesScreen: View {
    @StateObject private var session = ChatSessionBox()
    @State private var model: DevicesModel?
    var back: () -> Void

    var body: some View {
        Group {
            if let model {
                DevicesPage(model: model, back: back)
            } else {
                ProgressView()
            }
        }
        .fingusGround()
        .onDisappear { session.session.reset() }
        .task {
            if model == nil {
                let made = DevicesModel(session: session.session)
                session.session.onReset = { made.clear() }
                model = made
            }
            await model?.load()
        }
    }
}

/// What the Devices page has open over it: one device, or two it may merge.
private enum DevicesSheet: Identifiable {
    case device(String)
    case merge(OneMergeAsk)
    var id: String {
        switch self {
        case .device(let id): return "device|" + id
        case .merge(let ask): return "merge|" + ask.id
        }
    }
}

private struct DevicesPage: View {
    @ObservedObject var model: DevicesModel
    var back: () -> Void
    @State private var open: DevicesSheet?

    private func openDemoSheet() {
        if DemoMode.devicesSheetOpen, open == nil, let id = DemoMode.devicesSheetDevice { open = .device(id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button(action: back) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text("You").fx(Look.Size.tab, style: .subheadline)
                    }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel(DevicesWords.back)
                Spacer()
            }
            .padding(.horizontal, Look.Space.gutter)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Look.Space.snug) {
                    Text(DevicesWords.title).fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    if let mine = model.thisPhoneWaiting {
                        ChatWaitingNote(name: model.devices.first(where: { $0.parts.chat.contains(mine) })?.name, code: DeviceCode.shown(ecdh: mine.ecdh, sign: mine.sign),
                                        check: { Task { await model.load() } })
                    }
                    if let working = model.working {
                        Text(working + "\u{2026}").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    } else if let notice = model.notice {
                        Text(notice).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    if let stopped = model.stopped {
                        ChatStoppedNote(stopped: stopped, key: { Task { await model.load() } })
                    }
                    if model.loaded && model.devices.isEmpty && model.stopped == nil {
                        Text(DevicesWords.empty).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    }
                    ForEach(model.devices) { device in
                        DeviceRowView(device: device, thisChat: model.thisDevice) { open = .device(device.id) }
                    }
                    if !model.maybeSame.isEmpty {
                        Text(DevicesWords.mayBeSame).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).padding(.top, Look.Space.snug)
                        ForEach(model.maybeSame, id: \.a) { pair in
                            if let a = model.device(pair.a), let b = model.device(pair.b) {
                                MaybeSameRow(a: a, b: b, why: pair.why) { open = .merge(OneMergeAsk(a: a, b: b, why: pair.why)) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Look.Space.gutter)
                .padding(.top, Look.Space.hair)
                .padding(.bottom, Look.Space.gutter)
            }
        }
        .sheet(item: $open) { sheet in
            switch sheet {
            case .device(let id):
                DeviceSheet(model: model, id: id, merge: { open = .merge($0) }, done: { open = nil })
                    .presentationDetents([.medium, .large])
            case .merge(let ask):
                MergeSheet(model: model, ask: ask, done: { open = nil })
                    .presentationDetents([.medium, .large])
            }
        }
        // for the pictures: the sheet is opened once the invented list is there
        .onAppear { if model.loaded { openDemoSheet() } }
        .onChange(of: model.loaded) { loaded in if loaded { openDemoSheet() } }
    }
}

private struct DeviceRowView: View {
    let device: OneDevice
    let thisChat: String?
    let action: () -> Void

    var body: some View {
        let title = OneDeviceListing.title(device, thisChat: thisChat)
        let note = OneDeviceListing.note(device)
        let quiet = device.removing == nil && !device.waiting
        Button(action: action) {
            HStack(spacing: Look.Space.snug) {
                Image(systemName: device.removing != nil ? "trash" : device.waiting ? "hourglass" : "iphone").font(.system(size: 18, weight: .semibold))
                    .frame(width: Look.Space.sizeTap).foregroundStyle(Look.Palette.fg)
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
                    if !note.isEmpty { Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(quiet ? Look.Palette.soft : Look.Palette.now).lineLimit(2) }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Look.Palette.dim)
            }
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
            .fingusCard(radius: Look.Bubble.radiusRow)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(note.isEmpty ? title : "\(title). \(note)")
        .accessibilityHint("Opens this device")
    }
}

/// Two rows the PC thinks may be one device, and what it saw. Nothing is merged until she opens it and chooses.
private struct MaybeSameRow: View {
    let a: OneDevice
    let b: OneDevice
    let why: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Look.Space.hair) {
                Text("\(a.shownName) and \(b.shownName)").fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
                Text(why + ". Merge?").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
            }
            .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
            .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
            .fingusCard(radius: Look.Bubble.radiusRow)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel("\(a.shownName) and \(b.shownName). \(why). Merge?")
    }
}

/// One part of a device, drawn quietly: what it is and what is known of it.
private struct PartLine: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.hair) {
            Text(title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
            if !note.isEmpty { Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
        }
        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fingusCard(radius: Look.Bubble.radiusRow)
        .accessibilityElement(children: .combine)
    }
}

private struct SectionHeader: View {
    let words: String
    var body: some View {
        Text(words).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft).padding(.top, Look.Space.tight)
    }
}

private struct DeviceSheet: View {
    @ObservedObject var model: DevicesModel
    let id: String
    var merge: (OneMergeAsk) -> Void
    var done: () -> Void
    @State private var name = ""
    @State private var picking = false

    var body: some View {
        Group {
            if let d = model.device(id) {
                if let ask = model.asking, ask.device.id == d.id {
                    ConfirmNotYours(model: model, ask: ask)
                } else {
                    sheet(d)
                }
            } else {
                // gone from the list (removed, or merged into another): nothing left to show
                Color.clear.onAppear { done() }
            }
        }
        .fingusGround()
    }

    @ViewBuilder
    private func sheet(_ d: OneDevice) -> some View {
        let approvable = OneDeviceListing.approvable(d, devices: model.devices, thisChat: model.thisDevice)
        let blocked = OneDeviceListing.removalBlocked(d, devices: model.devices, thisChat: model.thisDevice)
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                Text(OneDeviceListing.title(d, thisChat: model.thisDevice)).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                Text(OneDeviceListing.note(d)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                if let working = model.working { Text(working + "\u{2026}").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                if let stopped = model.stopped { ChatStoppedNote(stopped: stopped, key: { Task { await model.load() } }) }
                parts(d)
                waiting(d, approvable: approvable)
                TextField("", text: $name, prompt: Text(DevicesWords.namePlaceholder).foregroundColor(Look.Palette.inputText))
                    .fx(Look.Size.input, style: .body).foregroundStyle(Look.Palette.fg)
                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeControl)
                    .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).fill(Look.Palette.input))
                    .accessibilityLabel(DevicesWords.namePlaceholder)
                FingusKey(title: DevicesWords.keepName, prominent: false) { Task { await model.rename(d, to: name) } }
                mergeBlock(d)
                removeBlock(d, blocked: blocked)
                Button(action: done) {
                    Text("Done").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
            }
            .padding(Look.Space.gutter)
        }
        .onAppear { name = d.name }
    }

    /// Its sign-ins, its chat keys (approved or waiting) and its file key, inside it.
    @ViewBuilder
    private func parts(_ d: OneDevice) -> some View {
        if !d.parts.session.isEmpty {
            SectionHeader(words: DevicesWords.signedIn)
            ForEach(d.parts.session) { s in
                PartLine(title: s.shownName, note: s.cut ? "Stopped" : DevicesWords.seen(OneDeviceListing.when(s.seen)))
            }
        }
        if !d.parts.chat.isEmpty {
            SectionHeader(words: DevicesWords.chatKeys)
            ForEach(d.parts.chat) { k in
                PartLine(title: k.label ?? k.name ?? "A chat key",
                         note: k.trusted ? (k.approvedBy == "machine" ? DevicesWords.approvedByPC : DevicesWords.approvedWord) : DevicesWords.waiting)
            }
        }
        if !d.parts.key.isEmpty {
            SectionHeader(words: DevicesWords.fileKey)
            ForEach(d.parts.key) { k in
                PartLine(title: k.label ?? "A file key", note: k.used.map { DevicesWords.seen(OneDeviceListing.when($0)) } ?? "")
            }
        }
    }

    /// A device that waits: the code of each waiting key (it is on its own screen too) and the key that approves after she has compared them.
    @ViewBuilder
    private func waiting(_ d: OneDevice, approvable: [OneChatKey]) -> some View {
        if d.waiting && approvable.isEmpty {
            Text(OneDeviceListing.isThisPhone(d, thisChat: model.thisDevice) ? ChatWords.waitingNote(d.shownName) : DevicesWords.removeNeedsApproval)
                .fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        }
        if !approvable.isEmpty {
            VStack(alignment: .leading, spacing: Look.Space.tight) {
                Text(DevicesWords.approveNote(d.shownName)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                ForEach(approvable) { k in
                    Text(DevicesWords.codeIs(OneDeviceListing.shownCode(k) ?? "?")).font(.system(.title3, design: .monospaced))
                        .foregroundStyle(Look.Palette.fg).textSelection(.enabled)
                }
                Text(DevicesWords.sameCode(d.shownName)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                FingusKey(title: DevicesWords.theyMatch) { Task { await model.approve(d) } }
                    .accessibilityLabel("\(DevicesWords.codeMatches). Approve \(d.shownName)")
            }
        }
    }

    /// Merging two rows that are one device: pick the other, then see both and why, then choose which name stays.
    @ViewBuilder
    private func mergeBlock(_ d: OneDevice) -> some View {
        let others = model.devices.filter { $0.id != d.id && $0.removing == nil }
        if d.removing == nil && !others.isEmpty {
            if picking {
                SectionHeader(words: DevicesWords.mergeTitle(d.shownName, "\u{2026}"))
                ForEach(others) { other in
                    Button {
                        let why = model.maybeSame.first { ($0.a == d.id && $0.b == other.id) || ($0.a == other.id && $0.b == d.id) }?.why
                        merge(OneMergeAsk(a: d, b: other, why: why))
                    } label: {
                        VStack(alignment: .leading, spacing: Look.Space.hair) {
                            Text(other.shownName).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                            Text(OneDeviceListing.note(other)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        }
                        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                        .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
                        .fingusCard(radius: Look.Bubble.radiusRow)
                    }
                    .buttonStyle(BubblePressStyle())
                }
            } else {
                Button { picking = true } label: {
                    VStack(alignment: .leading, spacing: Look.Space.hair) {
                        Text(DevicesWords.mergeWith).fx(Look.Size.itemName, style: .headline)
                        Text(DevicesWords.mergeIfSame).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    .foregroundStyle(Look.Palette.fg)
                    .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                    .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
                    .fingusCard(radius: Look.Bubble.radiusRow)
                }
                .buttonStyle(BubblePressStyle())
            }
        }
    }

    /// Removing takes every part of the device with it: it says what goes, asks twice, and says why when it cannot. A removal that is under way
    /// says "Removing…" and carries on where it stopped.
    @ViewBuilder
    private func removeBlock(_ d: OneDevice, blocked: String?) -> some View {
        if let blocked {
            Text(blocked).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        } else {
            let sure = model.armed == d.id
            let removing = d.removing
            let title = sure ? (removing != nil ? DevicesWords.removeCarryOnAgain : DevicesWords.removeSure)
                             : (removing != nil ? DevicesWords.removingName(d.shownName) : DevicesWords.remove(d.shownName))
            let note: String = {
                if let removing { return removing.stuck.map(DevicesWords.removeAgain) ?? DevicesWords.removeCarryOn }
                if !d.confirmFirst.isEmpty { return d.confirmFirst.joined(separator: ". ") + ". " + DevicesWords.removeConfirmFirst }
                return DevicesWords.removeHas(OneDeviceListing.has(d))
            }()
            Button { Task { await model.removeTapped(d) } } label: {
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(title).fx(Look.Size.itemName, style: .headline)
                    Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                }
                .foregroundStyle(sure ? Look.Palette.now : Look.Palette.fg)
                .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
                .fingusCard(radius: Look.Bubble.radiusRow)
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel(title)
        }
    }
}

/// A device that may be in use, or that was never matched to one she uses, is not removed in one step: this shows why and what it is, and only
/// "Confirm it's not yours" goes on (Systems/OneDeviceRemoval.lean `removal_needs_confirmation`). Sent back, the evidence is exactly what is shown.
private struct ConfirmNotYours: View {
    @ObservedObject var model: DevicesModel
    let ask: OneRemovalAsk

    var body: some View {
        let d = ask.device
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                Text(DevicesWords.isItYours(d.shownName)).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                if let stopped = model.stopped { ChatStoppedNote(stopped: stopped, key: { Task { await model.load() } }) }
                SectionHeader(words: DevicesWords.whyNotYet)
                ForEach(Array(ask.reasons.enumerated()), id: \.offset) { _, reason in PartLine(title: reason, note: "") }
                SectionHeader(words: DevicesWords.whatItIs)
                PartLine(title: d.shownName + (d.kind.isEmpty ? "" : " \u{00B7} " + d.kind),
                         note: DevicesWords.lastInUse(OneDeviceListing.when(Double(ask.info.seen))) + ". " + OneDeviceListing.has(d))
                FingusKey(title: DevicesWords.confirmNotYours) { Task { await model.confirmNotYours() } }
                    .accessibilityHint(DevicesWords.confirmNote(d.shownName))
                Text(DevicesWords.confirmNote(d.shownName)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                FingusKey(title: DevicesWords.keepIt, prominent: false) { model.leaveAsk() }
            }
            .padding(Look.Space.gutter)
        }
    }
}

/// Two devices that are really one: nothing is merged until she has seen both, and why they look alike, and picked which name stays.
private struct MergeSheet: View {
    @ObservedObject var model: DevicesModel
    let ask: OneMergeAsk
    var done: () -> Void

    var body: some View {
        // the rows as the list holds them now
        let a = model.device(ask.a.id) ?? ask.a, b = model.device(ask.b.id) ?? ask.b
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                Text(DevicesWords.mergeTitle(a.shownName, b.shownName)).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                if let stopped = model.stopped { ChatStoppedNote(stopped: stopped, key: { Task { await model.load() } }) }
                if let why = ask.why {
                    SectionHeader(words: DevicesWords.evidence)
                    PartLine(title: why, note: "")
                }
                SectionHeader(words: DevicesWords.becomeOne)
                PartLine(title: a.shownName, note: OneDeviceListing.note(a) + ". " + OneDeviceListing.has(a))
                PartLine(title: b.shownName, note: OneDeviceListing.note(b) + ". " + OneDeviceListing.has(b))
                FingusKey(title: DevicesWords.mergeAs(a.shownName)) { Task { await model.merge(keep: a, gone: b); if model.stopped == nil { done() } } }
                    .accessibilityHint(DevicesWords.mergeKeeps)
                FingusKey(title: DevicesWords.mergeAs(b.shownName), prominent: false) { Task { await model.merge(keep: b, gone: a); if model.stopped == nil { done() } } }
                    .accessibilityHint(DevicesWords.mergeKeeps)
                Text(DevicesWords.mergeKeeps).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                Button(action: done) {
                    Text("Done").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
            }
            .padding(Look.Space.gutter)
        }
        .fingusGround()
    }
}
