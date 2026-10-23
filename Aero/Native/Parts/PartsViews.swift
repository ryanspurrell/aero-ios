import SwiftUI
import WebKit

// Home, You and the Parts chooser. Only the approved tokens and shared pieces are used (Tokens.swift, FingusUI.swift): the bubble of a part's own
// colour, the page ground, the underline of the quiet keys, the pill key. No new look.

/// Core's list of parts, fetched when asked. Nothing of it is kept on the phone (it is read again each time), and with no PC the phone's own
/// parts are the whole list.
@MainActor
final class PartRegistry: ObservableObject {
    @Published private(set) var parts: [PartInfo] = PartCatalog.own

    func load() async {
        guard let base = AppInfo.address else { parts = PartCatalog.own; return }
        for cookie in await WKWebsiteDataStore.default().httpCookieStore.allCookies() { HTTPCookieStorage.shared.setCookie(cookie) }
        guard let (data, response) = try? await URLSession.shared.data(from: base.appendingPathComponent("look.json")),
              (response as? HTTPURLResponse)?.statusCode == 200 else { parts = PartCatalog.merged(core: nil); return }
        parts = PartCatalog.merged(core: PartCatalog.decodeCore(data))
    }
}

/// Core's icon words as SF Symbols (a symbol always goes with the name, never colour alone).
func partSymbol(_ icon: String) -> String {
    switch icon {
    case "chat": return "bubble.left"
    case "check": return "checkmark"
    case "up": return "music.note"
    case "play": return "play"
    case "photos": return "photo"
    case "globe": return "globe"
    case "video": return "video"
    case "money": return "dollarsign.circle"
    case "heart": return "heart"
    case "chart": return "chart.bar"
    case "calendar": return "calendar"
    case "place": return "mappin"
    case "mic": return "mic"
    case "home": return "house"
    case "folder": return "folder"
    case "project": return "square.stack"
    case "iphone": return "iphone"
    case "board": return "square.grid.2x2"
    default: return "circle"
    }
}

// MARK: Home

/// Home: the parts she added, as tiles. A tap goes into the part (a page over Home); the header says where she is.
struct PartsHomeScreen: View {
    @ObservedObject var registry: PartRegistry
    let added: [String]
    let hasPC: Bool
    var openYou: () -> Void
    var openWeb: () -> Void
    var webClosed: Int

    @State private var walk: [String] = []

    private var tiles: [PartInfo] { PartsSelection.tiles(added: added, parts: registry.parts, hasPC: hasPC) }
    private var graph: Holarchy { Holarchy.home(tiles: tiles.map(\.id)) }

    private func go(_ id: String?) {
        withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { walk = id.map { [$0] } ?? [] }
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Home").fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    Spacer()
                    ConnectionIsland()
                    Button(action: openYou) {
                        Text("You").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                    }
                }
                .padding(.horizontal, Look.Space.gutter)
                ScrollView(showsIndicators: false) {
                    if tiles.isEmpty {
                        VStack(spacing: Look.Space.snug) {
                            Text("No parts yet").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                            Button(action: openYou) {
                                Text("Add parts").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                                    .background(Capsule().fill(Look.Palette.accent))
                            }
                            .buttonStyle(BubblePressStyle())
                        }
                        .padding(Look.Space.gutter)
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: Look.Space.snug), GridItem(.flexible(), spacing: Look.Space.snug)], spacing: Look.Space.snug) {
                            ForEach(tiles) { part in
                                Button { go(part.id) } label: {
                                    VStack(alignment: .leading, spacing: Look.Space.tight) {
                                        Image(systemName: partSymbol(part.icon)).font(.system(size: 22, weight: .semibold))
                                        Text(part.name).fx(Look.Size.itemName, style: .headline)
                                    }
                                    .foregroundStyle(Look.Palette.ink)
                                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
                                    .padding(Look.Space.pad)
                                    .bubble(part.colourHex, radius: Look.Bubble.radiusCard)
                                }
                                .buttonStyle(BubblePressStyle())
                                .accessibilityLabel(part.name)
                            }
                        }
                        .padding(.horizontal, Look.Space.gutter)
                    }
                }
            }
            if let id = walk.first, graph.ok(walk), let part = tiles.first(where: { $0.id == id }) {
                PartPage(part: part, hasPC: hasPC, back: { go(nil) }, openWeb: openWeb, webClosed: webClosed)
                    .fingusGround()
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .onChange(of: tiles.map(\.id)) { _ in
            // a part taken away while she is inside it: the walk is no longer a place, so Home shows (ScreenWalk `openRecent_gone`)
            if !graph.ok(walk) { walk = [] }
        }
    }
}

/// A part's page: the header is the walk (Home, then the part), Back is a visible key, and the root view is the one compiled in for the part.
struct PartPage: View {
    let part: PartInfo
    let hasPC: Bool
    var back: () -> Void
    var openWeb: () -> Void
    var webClosed: Int

    var body: some View {
        switch part.root {
        case .organizer:
            NavigationStack {
                OrganizerDayScreen(open: { _ in if hasPC { openWeb() } }, openLists: { if hasPC { openWeb() } }, openChat: nil, back: back,
                                   menuTitle: hasPC ? "Open Aero" : "Connect your PC", menuAction: openWeb)
            }
        case .chat:
            if hasPC {
                ChatScreen(back: back, unlock: openWeb, returned: webClosed)
            } else {
                ChatNeedsPCScreen(back: back, connect: openWeb)
            }
        case .web:
            VStack(spacing: 0) {
                HStack {
                    Button(action: back) {
                        HStack(spacing: Look.Space.hair) {
                            Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                            Text("Home").fx(Look.Size.tab, style: .subheadline)
                        }
                        .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                    }
                    .accessibilityLabel("Back to Home")
                    Spacer()
                    ConnectionIsland()
                }
                .padding(.horizontal, Look.Space.gutter)
                VStack(spacing: Look.Space.snug) {
                    Text(part.name).fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    Button(action: openWeb) {
                        Text("Open in Aero").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                            .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                            .background(Capsule().fill(Look.Palette.accent))
                    }
                    .buttonStyle(BubblePressStyle())
                }
                .padding(Look.Space.gutter)
                Spacer()
            }
        }
    }
}

// MARK: You

/// You: the settings that are the phone's own. For now: the Parts chooser and the one test setting that puts Home first.
struct YouScreen: View {
    @ObservedObject var registry: PartRegistry
    @Binding var addedRaw: String
    @Binding var partsHome: Bool
    let hasPC: Bool
    var openAero: () -> Void
    var close: () -> Void

    @State private var showParts = false

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: Look.Space.snug) {
                HStack {
                    Text("You").fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                    Spacer()
                    Button("Done", action: close).fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                row("Parts", detail: "Add or remove") { withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { showParts = true } }
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Toggle(isOn: $partsHome) { Text("Home first").fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg) }
                    Text("Test. Off keeps the calendar first.").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                }
                .padding(Look.Space.pad).fingusCard()
                row(hasPC ? "Open Aero" : "Connect your PC", detail: nil, action: openAero)
                Spacer()
            }
            .padding(Look.Space.gutter)
            if showParts {
                PartsChooser(registry: registry, addedRaw: $addedRaw, hasPC: hasPC, back: {
                    withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { showParts = false }
                })
                .fingusGround()
                .transition(.move(edge: .trailing))
                .zIndex(1)
            }
        }
        .fingusGround()
    }

    private func row(_ title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                    if let detail { Text(detail).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Look.Palette.soft)
            }
            .padding(Look.Space.pad).frame(minHeight: Look.Space.sizeTap).fingusCard()
        }
        .buttonStyle(BubblePressStyle())
    }
}

/// Parts: every part this phone can offer, each with one key, Add or Remove. A part that needs a PC says so when there is none.
struct PartsChooser: View {
    @ObservedObject var registry: PartRegistry
    @Binding var addedRaw: String
    let hasPC: Bool
    var back: () -> Void

    private var added: [String] { PartsSelection.decode(addedRaw) }

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            HStack {
                Button(action: back) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text("You").fx(Look.Size.tab, style: .subheadline)
                    }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel("Back to You")
                Spacer()
            }
            Text("Parts").fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
            ScrollView(showsIndicators: false) {
                VStack(spacing: Look.Space.tight) {
                    ForEach(registry.parts) { part in
                        let isOn = added.contains(part.id)
                        let offered = PartsSelection.offered(part, hasPC: hasPC)
                        HStack(spacing: Look.Space.snug) {
                            Image(systemName: partSymbol(part.icon)).frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                                .foregroundStyle(Look.Palette.ink).bubble(part.colourHex, radius: Look.Bubble.radiusChip)
                            VStack(alignment: .leading, spacing: Look.Space.hair) {
                                Text(part.name).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                                if !offered { Text("Needs your PC").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                            }
                            Spacer()
                            Button {
                                addedRaw = PartsSelection.encode(isOn ? PartsSelection.removing(added, part.id) : PartsSelection.adding(added, part.id))
                            } label: {
                                Text(isOn ? "Remove" : "Add").fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                                    .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                                    .background(Capsule().fill(isOn ? Look.Palette.line : Look.Palette.accent))
                            }
                            .buttonStyle(BubblePressStyle())
                            .disabled(!isOn && !offered)
                            .opacity(!isOn && !offered ? 0.5 : 1)
                            .accessibilityLabel((isOn ? "Remove " : "Add ") + part.name)
                        }
                        .padding(Look.Space.snug).fingusCard()
                    }
                }
            }
        }
        .padding(Look.Space.gutter)
        .task { await registry.load() }
    }
}
