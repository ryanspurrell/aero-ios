import SwiftUI

// The Devices screen, a page that comes in from You: this phone's own state first (waiting for approval, with its fruit name and where to
// approve it), then every device with its name, kind and date added. A tap opens one: approve it, give it a name, remove it. Every action is a
// visible key; removing asks twice, as the page does. Look is Aero's (Tokens.swift, FingusUI.swift).

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

private struct DevicesPage: View {
    @ObservedObject var model: DevicesModel
    var back: () -> Void
    @State private var open: DeviceRow?

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
                        ChatWaitingNote(name: mine.name, code: DeviceCode.shown(ecdh: mine.ecdh, sign: mine.sign), check: { Task { await model.load() } })
                    }
                    if let notice = model.notice {
                        Text(notice).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    if let stopped = model.stopped {
                        VStack(alignment: .leading, spacing: Look.Space.tight) {
                            Text(stopped.text).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                            FingusKey(title: stopped.key) { Task { await model.load() } }
                        }
                    }
                    if model.loaded && model.rows.isEmpty && model.stopped == nil {
                        Text(DevicesWords.empty).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    }
                    ForEach(model.ordered) { row in
                        DeviceRowView(row: row, this: model.thisDevice) { open = row }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Look.Space.gutter)
                .padding(.top, Look.Space.hair)
                .padding(.bottom, Look.Space.gutter)
            }
        }
        .sheet(item: $open) { row in
            // the row as the list holds it now, so an approval or a new name shows when the list is read again
            DeviceSheet(model: model, row: model.rows.first(where: { $0.device == row.device }) ?? row) { open = nil }
                .presentationDetents([.medium, .large])
        }
    }
}

private struct DeviceRowView: View {
    let row: DeviceRow
    let this: String?
    let action: () -> Void

    var body: some View {
        let title = DeviceListing.title(row, this: this)
        let note = DeviceListing.note(row)
        Button(action: action) {
            HStack(spacing: Look.Space.snug) {
                Image(systemName: row.trusted ? "iphone" : "hourglass").font(.system(size: 18, weight: .semibold)).frame(width: Look.Space.sizeTap)
                    .foregroundStyle(Look.Palette.fg)
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
                    if !note.isEmpty { Text(note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(row.trusted ? Look.Palette.soft : Look.Palette.now).lineLimit(2) }
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

private struct DeviceSheet: View {
    @ObservedObject var model: DevicesModel
    let row: DeviceRow
    var done: () -> Void
    @State private var name = ""

    var body: some View {
        let canApprove = DeviceListing.canApprove(row, rows: model.rows, this: model.thisDevice)
        let blocked = DeviceListing.removalBlocked(row, rows: model.rows, this: model.thisDevice)
        ScrollView {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                Text(DeviceListing.title(row, this: model.thisDevice)).fx(Look.Size.head, style: .title3).foregroundStyle(Look.Palette.fg)
                Text(DeviceListing.note(row)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                if !row.trusted && !canApprove {
                    Text(row.device == model.thisDevice ? ChatWords.waitingNote(row.name) : DevicesWords.removeNeedsApproval)
                        .fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                }
                if canApprove {
                    VStack(alignment: .leading, spacing: Look.Space.tight) {
                        Text(DevicesWords.approveNote(row.shownName)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        Text(ChatWords.waitingCode(DeviceCode.shown(ecdh: row.ecdh, sign: row.sign))).font(.system(.title3, design: .monospaced))
                            .foregroundStyle(Look.Palette.fg).textSelection(.enabled)
                        Text(DevicesWords.codeQuestion).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                        FingusKey(title: DevicesWords.codeMatches) { Task { await model.approve(row); done() } }
                            .accessibilityLabel("\(DevicesWords.codeMatches). Approve \(row.shownName)")
                    }
                }
                TextField("", text: $name, prompt: Text(DevicesWords.namePlaceholder).foregroundColor(Look.Palette.inputText))
                    .fx(Look.Size.input, style: .body).foregroundStyle(Look.Palette.fg)
                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeControl)
                    .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusRow, style: .continuous).fill(Look.Palette.input))
                    .accessibilityLabel(DevicesWords.namePlaceholder)
                FingusKey(title: DevicesWords.keepName, prominent: false) { Task { await model.rename(row, to: name); done() } }
                if let blocked {
                    Text(blocked).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                } else {
                    let sure = model.armed == row.device
                    Button { Task { await model.removeTapped(row) } } label: {
                        VStack(alignment: .leading, spacing: Look.Space.hair) {
                            Text(sure ? DevicesWords.removeSure : DevicesWords.remove(row.shownName)).fx(Look.Size.itemName, style: .headline)
                            Text(DevicesWords.removeNote).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        }
                        .foregroundStyle(sure ? Look.Palette.now : Look.Palette.fg)
                        .padding(.horizontal, Look.Space.pad).padding(.vertical, Look.Space.padY)
                        .frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl, alignment: .leading)
                        .fingusCard(radius: Look.Bubble.radiusRow)
                    }
                    .buttonStyle(BubblePressStyle())
                    .accessibilityLabel(sure ? DevicesWords.removeSure : DevicesWords.remove(row.shownName))
                    .onChange(of: model.rows) { rows in if !rows.contains(where: { $0.device == row.device }) { done() } }
                }
                Button(action: done) {
                    Text("Done").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
            }
            .padding(Look.Space.gutter)
        }
        .fingusGround()
        .onAppear { name = row.name ?? "" }
    }
}
