import SwiftUI
import UIKit

// The Location part's screen, read-only: the map fills the screen, a sheet over it holds where she is now and two tabs, Timeline and Places
// (the web app's Location screen without its Settings tab and without anything that writes: naming a place, making it home, removing it,
// pausing, setting up OwnTracks, the map's own settings; those stay in Aero on the PC). Look: the app's own tokens only; the sheet's three
// heights as the web page has them (a strip, about half, nearly all), each reachable by a tap on the grab bar as well as by dragging.
//
// Without a PC: "Maps need your PC" and a key that connects one. The map's squares, letters and symbols come from the PC; the phone has none.
//
// Without sight (standing rule 24): everything the map shows is also in the sheet as text in the order of the day (the visits and trips,
// the places with their distances, where she is now), and the map itself is one element labelled "Map".

struct MapsScreen: View {
    var back: () -> Void
    var connect: () -> Void

    @StateObject private var store = MapsStore()
    @Environment(\.colorScheme) private var scheme
    @State private var detent: Detent = .mid
    @State private var dragged: CGFloat = 0

    enum Detent: CaseIterable {
        case low, mid, high
        /// The share of the screen's height. The strip is the head and the tabs; about half is the web page's 46%; nearly all leaves the keys.
        var share: CGFloat { self == .low ? 0.2 : self == .mid ? 0.46 : 0.82 }
        var next: Detent { self == .low ? .mid : self == .mid ? .high : .low }
        var bigger: Detent { self == .low ? .mid : .high }
        var smaller: Detent { self == .high ? .mid : .low }
    }

    private var night: Bool { scheme == .dark }

    var body: some View {
        Group {
            switch store.phase {
            case .needsPC:
                MapsMessagePage(title: "Location", message: MapsText.needsPC, key: ChatWords.connectPC, back: back, action: connect)
            case .failed(let words):
                MapsMessagePage(title: "Location", message: words, key: "Try again", diagnosis: "pc_unreachable", back: back, action: { Task { await store.load() } })
            case .loading:
                MapsMessagePage(title: "Location", message: nil, key: nil, back: back, action: {})
            case .ready:
                ready
            }
        }
        .fingusGround()
        .task { await store.load() }
    }

    // MARK: the map and its sheet

    private var ready: some View {
        GeometryReader { geo in
            let total = geo.size.height
            let height = min(total * 0.92, max(150, total * detent.share - dragged))
            ZStack(alignment: .bottom) {
                map(bottomInset: height - geo.safeAreaInsets.bottom)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    topKeys
                    Spacer()
                }
                .padding(.horizontal, Look.Space.inset)
                .padding(.bottom, height)
                sheet(height: height)
            }
        }
    }

    @ViewBuilder private func map(bottomInset: CGFloat) -> some View {
        let key = "\(night ? "dark" : "light")|\(AppInfo.address?.absoluteString ?? "")"
        if let server = AppInfo.address, let layers = MapsStyle.bundledLayers(night: night), let style = MapsStyle.json(server: server, night: night, layers: layers) {
            MapLibreView(style: style, styleKey: key, overlay: MapsOverlay.make(overview: store.overview, day: store.day, isToday: store.isToday),
                         look: store.look, bottomInset: max(0, bottomInset), accent: UIColor(Look.Palette.accent), night: night)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: Look.Space.hair) {
                        // the credit is always on the map, as the data's licence asks (OpenStreetMap: ODbL; Protomaps' basemap design: CC0)
                        Text(MapsText.creditLine).fx(Look.Size.itemMeta, style: .caption1).foregroundStyle(Look.Palette.soft)
                            .padding(.horizontal, Look.Space.tight).padding(.vertical, Look.Space.hair)
                            .background(Capsule().fill(Look.Palette.card.opacity(0.85)))
                        if let says = store.mapSays {
                            Text(says).fx(Look.Size.itemMeta, style: .caption1).foregroundStyle(Look.Palette.soft)
                                .padding(.horizontal, Look.Space.tight).padding(.vertical, Look.Space.hair)
                                .background(Capsule().fill(Look.Palette.card.opacity(0.85)))
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .padding(.top, 64).padding(.leading, Look.Space.inset)
                }
                .accessibilityElement(children: .contain)
        } else {
            Look.Palette.page
        }
    }

    private var topKeys: some View {
        HStack {
            Button(action: back) {
                HStack(spacing: Look.Space.hair) {
                    Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                    Text("Home").fx(Look.Size.tab, style: .subheadline)
                }
                .foregroundStyle(Look.Palette.fg).padding(.horizontal, Look.Space.snug).frame(minHeight: Look.Space.sizeTap)
                .background(Capsule().fill(Look.Palette.card.opacity(0.92)))
            }
            .buttonStyle(BubblePressStyle())
            .accessibilityLabel("Back to Home")
            Spacer()
            ConnectionIsland()
            VStack(spacing: Look.Space.tight) {
                round("location", "Where you are") { store.lookHere() }
                round("point.topleft.down.to.point.bottomright.curvepath", "The whole day") { store.lookDay() }
            }
        }
        .padding(.top, Look.Space.tight)
    }

    private func round(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(Look.Palette.fg)
                .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
                .background(Circle().fill(Look.Palette.card.opacity(0.92)))
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityLabel(label)
    }

    private func sheet(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { detent = detent.next }
            } label: {
                Capsule().fill(Look.Palette.line).frame(width: 40, height: 5)
                    .frame(maxWidth: .infinity, minHeight: Look.Space.sizeTap)
            }
            .accessibilityLabel(detent == .high ? "Make this sheet smaller" : "Make this sheet bigger")
            head
            tabs
            ScrollView(showsIndicators: false) {
                VStack(spacing: Look.Space.tight) {
                    if store.tab == .timeline { timeline } else { places }
                }
                .padding(.horizontal, Look.Space.gutter).padding(.vertical, Look.Space.snug)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Look.Bubble.radiusNext, topTrailingRadius: Look.Bubble.radiusNext)
                .fill(Look.Palette.card)
                .shadow(color: Look.Palette.shadow.opacity(Look.Bubble.shadowNext.alpha), radius: Look.Bubble.shadowNext.blur / 2, x: 0, y: -Look.Bubble.shadowNext.y)
                .ignoresSafeArea(edges: .bottom)
        )
        .gesture(DragGesture(minimumDistance: 12)
            .onChanged { dragged = $0.translation.height }
            .onEnded { value in
                let up = value.translation.height < 0
                withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) {
                    if abs(value.translation.height) > 40 { detent = up ? detent.bigger : detent.smaller }
                    dragged = 0
                }
            })
    }

    @ViewBuilder private var head: some View {
        if let o = store.overview {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(MapsText.headline(o.now)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                    Text(MapsText.subline(o.now)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    if o.settings?.paused == true {
                        Text("Recording is paused").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                }
                Spacer()
                if let chip = MapsText.homeChip(o.now) {
                    Text(chip).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.snug).frame(minHeight: 30)
                        .background(Capsule().fill(o.now.home?.inside?.on == true ? Look.Palette.accent : Look.Palette.line))
                }
            }
            .padding(.horizontal, Look.Space.gutter)
            .accessibilityElement(children: .combine)
        }
    }

    private var tabs: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach([MapsStore.Tab.timeline, .places], id: \.rawValue) { t in
                    Button { withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { store.tab = t; if detent == .low { detent = .mid } } } label: {
                        Text(t.rawValue).fx(Look.Size.tab, style: .subheadline)
                            .foregroundStyle(store.tab == t ? Look.Palette.fg : Look.Palette.soft)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) { if store.tab == t { Rectangle().fill(Look.Palette.fg).frame(height: 3).offset(y: 1) } }
                            .frame(minHeight: Look.Space.sizeTap)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.tab == t ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            Rectangle().fill(Look.Palette.rule).frame(height: 2)
        }
        .padding(.horizontal, Look.Space.gutter)
    }

    // MARK: Timeline

    @ViewBuilder private var timeline: some View {
        HStack {
            stepKey("chevron.left", "Day before", enabled: true) { Task { await store.step(-1) } }
            Spacer()
            Text(MapsText.dayName(store.dayKey, today: store.today)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
            Spacer()
            stepKey("chevron.right", "Day after", enabled: !store.isToday) { Task { await store.step(1) } }
        }
        if let failed = store.dayFailure {
            Text(failed).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            FindOutWhyKey(diagnosis: "pc_unreachable")
        }
        let rows = store.day.map { MapsText.timelineRows($0, places: store.overview?.places ?? []) } ?? []
        if rows.isEmpty {
            Text(store.isToday ? "No places yet today" : "No places this day").fx(Look.Size.calm, style: .subheadline)
                .foregroundStyle(Look.Palette.soft).padding(.top, Look.Space.snug)
        }
        ForEach(rows) { row in rowView(row) }
    }

    private func stepKey(_ symbol: String, _ label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .bold)).foregroundStyle(Look.Palette.fg)
                .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
        }
        .buttonStyle(BubblePressStyle())
        .disabled(!enabled).opacity(enabled ? 1 : 0.4)
        .accessibilityLabel(label)
    }

    // MARK: Places

    @ViewBuilder private var places: some View {
        let rows = MapsText.placeRows(store.overview?.places ?? [], now: store.overview?.now ?? MapsNow(known: false))
        if rows.isEmpty {
            Text("No places yet").fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            Text("Name where you are in Aero on your PC").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        }
        ForEach(rows) { row in rowView(row) }
    }

    // MARK: a row: a tap takes the map there

    private func rowView(_ row: MapsText.Row) -> some View {
        Button {
            switch row.target {
            case .visit(let lat, let lon), .place(let lat, let lon): store.send(.point(lat: lat, lon: lon))
            case .trip(let from, let to): store.send(.trip(from: from, to: to))
            case .none: break
            }
            withAnimation(.spring(response: Look.springResponse, dampingFraction: Look.springDamping)) { if detent == .high { detent = .mid } }
        } label: {
            HStack {
                Image(systemName: row.isTrip ? "arrow.right" : row.isHome ? "house" : "mappin").frame(width: 24)
                    .foregroundStyle(Look.Palette.soft)
                VStack(alignment: .leading, spacing: Look.Space.hair) {
                    Text(row.title).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                    if !row.note.isEmpty { Text(row.note).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft) }
                }
                Spacer()
                if !row.value.isEmpty { Text(row.value).fx(Look.Size.rowTime, style: .footnote).foregroundStyle(Look.Palette.soft) }
            }
            .padding(Look.Space.pad).frame(minHeight: Look.Space.sizeTap).fingusCard(radius: Look.Bubble.radiusRow)
        }
        .buttonStyle(BubblePressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.target == .none ? "" : "Shows it on the map")
    }
}

/// A page with one plain message and one key, for the states with no map: loading, a failure, and no PC.
struct MapsMessagePage: View {
    let title: String
    let message: String?
    let key: String?
    /// Doctor's id for this failure, for the Find out why key; nil where nothing failed.
    var diagnosis: String?
    var back: () -> Void
    var action: () -> Void

    var body: some View {
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
                Text(title).fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                if let message {
                    Text(message).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).multilineTextAlignment(.center)
                } else {
                    ProgressView()
                }
                if let key {
                    Button(action: action) {
                        Text(key).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                            .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                            .background(Capsule().fill(Look.Palette.accent))
                    }
                    .buttonStyle(BubblePressStyle())
                }
                if let diagnosis { FindOutWhyKey(diagnosis: diagnosis) }
            }
            .padding(Look.Space.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
