import SwiftUI

// Photos, read-only, drawn like the familiar Photos app (a grid by month, albums, a photo full screen you swipe) in Fingus's look. Only the
// approved tokens and shared pieces are used (Tokens.swift, FingusUI.swift). Everything on screen is a thing inside a thing: Home, Photos, then what she walked into;
// the header says so (design__native_app_as_nested_things_2026-10-23.md). A photo grows from its own tile and Back returns to that tile.
// Every swipe has a visible key: Previous and Next for the swipe between photos, Back for the edge swipe.

private let spring = Animation.spring(response: Look.springResponse, dampingFraction: Look.springDamping)

// MARK: small pieces

/// A picture, from the memory cache or the PC. A covered one is never asked for: it is a plain cover with its word.
struct PhotoPicture: View {
    let images: PhotoImages
    let id: String
    let version: String?
    let what: String
    let covered: Bool
    var fill = true
    @State private var image: UIImage?
    @State private var gaveUp = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit)
            } else {
                Rectangle().fill(Look.Palette.card)
                if covered {
                    Text(PhotosWords.covered).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                } else if gaveUp {
                    Image(systemName: "photo").foregroundStyle(Look.Palette.dim)
                }
            }
        }
        .task(id: id + what) {
            guard !covered else { return }
            image = images.cached(id, what, version: version)
            if image == nil {
                image = await images.image(id, what, version: version)
                gaveUp = image == nil
            }
        }
    }
}

/// A line that says what happened and offers the next step: Try again, and (with a PC to ask) Doctor's Find out why.
struct PhotosProblem: View {
    let phase: PhotosPhase
    var retry: () -> Void
    var unlock: () -> Void

    var body: some View {
        VStack(spacing: Look.Space.snug) {
            switch phase {
            case .locked:
                Text(PhotosWords.locked).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                pill(PhotosWords.unlock, unlock)
            case .signedOut:
                Text(PhotosWords.signIn).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                pill(PhotosWords.openInAero, unlock)
            default:
                Text(PhotosWords.couldntLoad).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                FailureKeys(tryAgain: PhotosWords.tryAgain, diagnosis: "pc_unreachable", retry: retry)
            }
        }
        .multilineTextAlignment(.center)
        .padding(Look.Space.gutter)
        .frame(maxWidth: .infinity)
    }

    private func pill(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                .background(Capsule().fill(Look.Palette.accent))
        }
        .buttonStyle(BubblePressStyle())
    }
}

/// Photos with no PC set up: it says so, with the key that connects one.
struct PhotosNeedsPCScreen: View {
    var back: () -> Void
    var connect: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) {
                    HStack(spacing: Look.Space.hair) {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                        Text(PhotosWords.home).fx(Look.Size.tab, style: .subheadline)
                    }
                    .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel("Back to Home")
                Spacer()
            }
            .padding(.horizontal, Look.Space.gutter)
            VStack(spacing: Look.Space.snug) {
                Text(PhotosWords.needsPC).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).multilineTextAlignment(.center)
                Button(action: connect) {
                    Text(PhotosWords.connectPC).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                        .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                        .background(Capsule().fill(Look.Palette.accent))
                }
                .buttonStyle(BubblePressStyle())
            }
            .padding(Look.Space.gutter)
            Spacer()
        }
        .fingusGround()
    }
}

// MARK: the header: the walk

/// Home, Photos, then what she walked into. The part's icon and colour stay in view when names are folded away; with more than three steps the
/// earlier ones fold into "…", which opens the whole walk in one tap. Tapping a step is the same as pressing Back until there.
struct PhotosHeader: View {
    let part: PartInfo
    let crumbs: [String]
    var tap: (Int) -> Void

    private var folded: Bool { crumbs.count > 3 }
    private var firstShown: Int { folded ? crumbs.count - 3 : 0 }

    var body: some View {
        HStack(spacing: Look.Space.hair) {
            Image(systemName: partSymbol(part.icon)).font(.system(size: 14, weight: .semibold)).foregroundStyle(Look.Palette.ink)
                .frame(width: 28, height: 28).bubble(part.colourHex, radius: Look.Bubble.radiusChip)
                .accessibilityHidden(true)
            if folded {
                Menu {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, name in
                        Button(name) { tap(i) }
                    }
                } label: {
                    Text("\u{2026}").fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minWidth: Look.Space.sizeTap, minHeight: Look.Space.sizeTap)
                }
                .accessibilityLabel("Show the whole path")
            }
            ForEach(Array(crumbs.enumerated()).filter { $0.offset >= firstShown }, id: \.offset) { i, name in
                if i > firstShown || folded { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Look.Palette.dim).accessibilityHidden(true) }
                Button { tap(i) } label: {
                    Text(name).fx(Look.Size.tab, style: .subheadline).lineLimit(1)
                        .foregroundStyle(i == crumbs.count - 1 ? Look.Palette.fg : Look.Palette.soft)
                        .frame(minHeight: Look.Space.sizeTap)
                }
                .disabled(i == crumbs.count - 1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Look.Space.gutter)
    }
}

// MARK: the grid

/// The months of the library or of one album, as a grid you scroll. A month's items are asked for when its heading comes near.
struct PhotosGridPage: View {
    @ObservedObject var model: PhotosMonthsModel
    let images: PhotoImages
    let namespace: Namespace.ID
    /// The photo that is open, whose own tile is the spot the viewer grows from.
    let openID: String?
    var open: (PhotoItem) -> Void
    var retry: () -> Void
    var unlock: () -> Void
    /// Where Back returns to: scrolled to when the token changes.
    let spot: String?
    let spotToken: Int

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.months.isEmpty {
                Text(PhotosWords.empty).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(alignment: .leading, spacing: Look.Space.tight, pinnedViews: [.sectionHeaders]) {
                            ForEach(model.months) { month in
                                Section {
                                    section(month)
                                } header: {
                                    HStack {
                                        Text(PhotosFormat.monthTitle(month.month)).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                                        Text("\(month.count)").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                                        Spacer()
                                    }
                                    .padding(.horizontal, Look.Space.gutter).padding(.vertical, Look.Space.hair)
                                    .background(Look.Palette.page.opacity(0.92))
                                    .task { await model.loadMonth(month.month) }
                                }
                            }
                        }
                    }
                    .onChange(of: spotToken) { _ in
                        if let spot { proxy.scrollTo(spot, anchor: .center) }
                    }
                }
            }
        default:
            PhotosProblem(phase: model.phase, retry: retry, unlock: unlock)
        }
    }

    @ViewBuilder
    private func section(_ month: PhotoMonth) -> some View {
        if let items = model.items[month.month] {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { item in
                    Button { open(item) } label: {
                        tile(item)
                    }
                    .buttonStyle(.plain)
                    .id(item.id)
                    .accessibilityLabel(PhotosTile.label(item))
                }
            }
        } else if model.failedMonths.contains(month.month) {
            HStack {
                Text(PhotosWords.couldntLoad).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                Button(PhotosWords.tryAgain) { Task { await model.retryMonth(month.month) } }
                    .fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.fg).frame(minHeight: Look.Space.sizeTap)
            }
            .padding(.horizontal, Look.Space.gutter)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private func tile(_ item: PhotoItem) -> some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(PhotoPicture(images: images, id: item.id, version: item.version, what: "thumbnail", covered: item.covered))
            .overlay(alignment: .bottomLeading) {
                if item.favourite { Image(systemName: "heart.fill").font(.system(size: 11)).foregroundStyle(.white).shadow(radius: 2).padding(5) }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.video, let length = PhotosFormat.length(item.ms) { Text(length).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).shadow(radius: 2).padding(5) }
            }
            .overlay(alignment: .topTrailing) {
                if item.video && PhotosFormat.length(item.ms) == nil { Image(systemName: "video.fill").font(.system(size: 11)).foregroundStyle(.white).shadow(radius: 2).padding(5) }
                else if item.live { Image(systemName: "livephoto").font(.system(size: 11)).foregroundStyle(.white).shadow(radius: 2).padding(5) }
            }
            .clipped()
            .matchedGeometryEffect(id: item.id, in: namespace, isSource: true)
            .opacity(openID == item.id ? 0 : 1)
    }
}

enum PhotosTile {
    /// What a screen reader says for a tile: kind, length, date; not the place or the name.
    static func label(_ item: PhotoItem) -> String {
        var parts = [item.video ? "Video" : (item.live ? "Live photo" : "Photo")]
        if let length = PhotosFormat.length(item.ms), item.video { parts.append(length) }
        if item.covered { parts.append(PhotosWords.covered) }
        if item.favourite { parts.append("favourite") }
        parts.append(PhotosFormat.when(item.taken))
        return parts.joined(separator: ", ")
    }
}

// MARK: albums

struct PhotosAlbumsPage: View {
    @ObservedObject var model: PhotosAlbumsModel
    let images: PhotoImages
    var open: (PhotoAlbum) -> Void
    var retry: () -> Void
    var unlock: () -> Void

    private let columns = [GridItem(.flexible(), spacing: Look.Space.snug), GridItem(.flexible(), spacing: Look.Space.snug)]

    var body: some View {
        switch model.phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            if model.albums.isEmpty {
                Text(PhotosWords.noAlbums).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVGrid(columns: columns, spacing: Look.Space.snug) {
                        ForEach(model.albums) { album in
                            Button { open(album) } label: {
                                VStack(alignment: .leading, spacing: Look.Space.hair) {
                                    Color.clear.aspectRatio(1, contentMode: .fit)
                                        .overlay(Group {
                                            if let cover = album.cover {
                                                PhotoPicture(images: images, id: cover, version: nil, what: "thumbnail", covered: album.covered)
                                            } else {
                                                Rectangle().fill(Look.Palette.card)
                                            }
                                        })
                                        .clipShape(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip))
                                    Text(album.name).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg).lineLimit(1)
                                    Text("\(album.count)").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                                }
                            }
                            .buttonStyle(BubblePressStyle())
                            .accessibilityLabel("\(album.name), \(album.count)")
                        }
                    }
                    .padding(.horizontal, Look.Space.gutter)
                }
            }
        default:
            PhotosProblem(phase: model.phase, retry: retry, unlock: unlock)
        }
    }
}

// MARK: one photo, full screen

/// A photo full screen. Swipe sideways for the next; Previous and Next keys do the same. Back shrinks it to its own tile.
struct PhotoViewer: View {
    let items: [PhotoItem]
    @Binding var selection: String
    let images: PhotoImages
    let namespace: Namespace.ID
    let infoModel: PhotoInfoModel
    var back: () -> Void
    var openWeb: () -> Void

    @State private var showInfo = false

    private var index: Int { items.firstIndex { $0.id == selection } ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selection) {
                ForEach(items) { item in
                    page(item).tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack {
                key("chevron.left", PhotosWords.previous, enabled: index > 0) { step(-1) }
                Spacer()
                Text("\(index + 1) / \(items.count)").fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                Spacer()
                key("info.circle", PhotosWords.info, enabled: true) { showInfo = true }
                key("chevron.right", PhotosWords.next, enabled: index < items.count - 1) { step(1) }
            }
            .padding(.horizontal, Look.Space.gutter)
        }
        .fingusGround()
        .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
        .sheet(isPresented: $showInfo) { PhotoInfoSheet(model: infoModel, id: selection, close: { showInfo = false }) }
    }

    private func step(_ by: Int) {
        let next = index + by
        guard items.indices.contains(next) else { return }
        withAnimation(spring) { selection = items[next].id }
    }

    private func key(_ symbol: String, _ label: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(Look.Palette.fg)
                .frame(width: Look.Space.sizeTap, height: Look.Space.sizeTap)
        }
        .disabled(!enabled).opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func page(_ item: PhotoItem) -> some View {
        VStack(spacing: Look.Space.snug) {
            if item.video {
                ZStack {
                    PhotoPicture(images: images, id: item.id, version: item.version, what: "preview", covered: item.covered, fill: false)
                    Image(systemName: "play.fill").font(.system(size: 28)).foregroundStyle(.white).shadow(radius: 4).accessibilityHidden(true)
                }
                VStack(spacing: Look.Space.hair) {
                    Text(PhotosWords.videoInAero).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
                    Button(action: openWeb) {
                        Text(PhotosWords.openInAero).fx(Look.Size.pill, style: .footnote).foregroundStyle(Look.Palette.ink)
                            .padding(.horizontal, Look.Space.pad).frame(minHeight: Look.Space.sizeTap)
                            .background(Capsule().fill(Look.Palette.accent))
                    }
                    .buttonStyle(BubblePressStyle())
                }
            } else {
                PhotoPicture(images: images, id: item.id, version: item.version, what: "preview", covered: item.covered, fill: false)
            }
            Text(PhotosFormat.when(item.taken)).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
        }
        .padding(Look.Space.snug)
    }
}

struct PhotoInfoSheet: View {
    @ObservedObject var model: PhotoInfoModel
    let id: String
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Look.Space.snug) {
            HStack {
                Text(PhotosWords.info).fx(Look.Size.title, style: .title2).foregroundStyle(Look.Palette.fg)
                Spacer()
                Button("Done", action: close).fx(Look.Size.tab, style: .subheadline).foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
            }
            switch model.phase {
            case .loading:
                ProgressView().frame(maxWidth: .infinity)
            case .ready:
                if let info = model.info { rows(info) }
            default:
                Text(PhotosWords.couldntLoad).fx(Look.Size.calm, style: .subheadline).foregroundStyle(Look.Palette.soft)
            }
            Spacer()
        }
        .padding(Look.Space.gutter)
        .fingusGround()
        .task(id: id) { await model.load(id) }
    }

    private func rows(_ info: PhotoInfo) -> some View {
        let size = [info.pixels.count == 2 ? "\(info.pixels[0]) \u{00D7} \(info.pixels[1])" : nil, PhotosFormat.bytes(info.size)].compactMap { $0 }.joined(separator: " \u{00B7} ")
        let lines: [(String, String)] = [
            ("Taken", PhotosFormat.when(info.taken)),
            ("Place", info.place),
            ("Camera", [info.camera, info.shot].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")),
            ("Size", size),
            ("File", info.name),
            ("Albums", info.albums.compactMap(\.name).joined(separator: ", ")),
            ("People", info.people.compactMap(\.name).joined(separator: ", ")),
            ("Description", info.said ?? ""),
        ].filter { !$0.1.isEmpty }
        return ScrollView(showsIndicators: false) {
            VStack(spacing: Look.Space.tight) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: Look.Space.hair) {
                        Text(line.0).fx(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                        Text(line.1).fx(Look.Size.itemName, style: .headline).foregroundStyle(Look.Palette.fg)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Look.Space.pad).fingusCard()
                }
            }
        }
    }
}

// MARK: Photos

/// The Photos part: tabs for the library and the albums, an album as a page over Albums, a photo as a page over its grid.
struct PhotosScreen: View {
    let part: PartInfo
    /// Back to Home.
    var back: () -> Void
    /// Opens Aero (the web view): to unlock Locked photos, play a video, sign in, and where Doctor diagnoses a failure.
    var openWeb: () -> Void

    @StateObject private var library: PhotosMonthsModel
    @StateObject private var albums: PhotosAlbumsModel
    @StateObject private var info: PhotoInfoModel
    @State private var albumModel: PhotosMonthsModel?
    @State private var walk = PhotosWalk()
    @State private var selection = ""
    @State private var spot: String?
    @State private var spotToken = 0
    @Namespace private var grow
    private let api: PhotosAPI
    private let images: PhotoImages

    init(part: PartInfo, back: @escaping () -> Void, openWeb: @escaping () -> Void, api: PhotosAPI = PhotosAPI()) {
        self.part = part
        self.back = back
        self.openWeb = openWeb
        self.api = api
        self.images = PhotoImages(api: api)
        _library = StateObject(wrappedValue: PhotosMonthsModel(api: api))
        _albums = StateObject(wrappedValue: PhotosAlbumsModel(api: api))
        _info = StateObject(wrappedValue: PhotoInfoModel(api: api))
    }

    private var openPhoto: String? { if case .photo(let id) = walk.current { return id } else { return nil } }
    private var inAlbum: Bool { walk.places.contains { if case .album = $0 { return true } else { return false } } }
    /// The model the open grid (and so the viewer) reads from: the album's if she is inside one.
    private var gridModel: PhotosMonthsModel { (inAlbum ? albumModel : nil) ?? library }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Button(action: goBack) {
                        HStack(spacing: Look.Space.hair) {
                            Image(systemName: "chevron.left").font(.system(size: 15, weight: .bold))
                            Text(walk.isAtTab ? PhotosWords.home : walk.crumbs[walk.crumbs.count - 2]).fx(Look.Size.tab, style: .subheadline).lineLimit(1)
                        }
                        .foregroundStyle(Look.Palette.soft).frame(minHeight: Look.Space.sizeTap)
                    }
                    .accessibilityLabel("Back to " + (walk.isAtTab ? PhotosWords.home : walk.crumbs[walk.crumbs.count - 2]))
                    Spacer()
                    ConnectionIsland()
                }
                .padding(.horizontal, Look.Space.gutter)
                PhotosHeader(part: part, crumbs: walk.crumbs, tap: tapped)
                if walk.isAtTab { tabs }
                pages
            }
            if let id = openPhoto {
                PhotoViewer(items: gridModel.flat, selection: $selection, images: images, namespace: grow, infoModel: info,
                            back: { goBack() }, openWeb: openWeb)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(2)
                    .onAppear { selection = id }
                    .onChange(of: selection) { now in
                        // swiping moves the photo she is on; the walk follows it, and Back returns to that photo's tile
                        if case .photo = walk.current, now != id { replacePhoto(now) }
                    }
            }
        }
        .fingusGround()
        .task { await library.load(); await albums.load() }
    }

    // MARK: the pages

    private var tabs: some View {
        HStack(spacing: Look.Space.pad) {
            ForEach([PhotosPlace.library, PhotosPlace.albums], id: \.label) { tab in
                let on = walk.current == tab
                Button {
                    withAnimation(spring) { walk.switchTab(tab) }
                } label: {
                    Text(tab.label).fx(Look.Size.tab, style: .subheadline).foregroundStyle(on ? Look.Palette.fg : Look.Palette.soft)
                        .frame(minHeight: Look.Space.sizeTap)
                        .overlay(alignment: .bottom) { Rectangle().fill(on ? Look.Palette.fg : Color.clear).frame(height: 2) }
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, Look.Space.gutter)
    }

    @ViewBuilder
    private var pages: some View {
        ZStack {
            switch walk.places.first ?? .library {
            case .albums:
                PhotosAlbumsPage(model: albums, images: images, open: openAlbum, retry: { Task { await albums.load() } }, unlock: openWeb)
            default:
                grid(library)
            }
            if inAlbum, let m = albumModel {
                grid(m).fingusGround().transition(.move(edge: .trailing)).zIndex(1)
            }
        }
    }

    private func grid(_ model: PhotosMonthsModel) -> some View {
        PhotosGridPage(model: model, images: images, namespace: grow, openID: openPhoto, open: { item in openItem(item) },
                       retry: { Task { await model.load() } }, unlock: openWeb, spot: spot, spotToken: spotToken)
    }

    // MARK: moving

    private func openAlbum(_ album: PhotoAlbum) {
        let model = PhotosMonthsModel(api: api, album: album.id)
        albumModel = model
        withAnimation(spring) { walk.enter(.album(id: album.id, name: album.name)) }
        Task { await model.load() }
    }

    private func openItem(_ item: PhotoItem) {
        selection = item.id
        withAnimation(spring) { walk.enter(.photo(id: item.id)) }
    }

    /// Swiping from one photo to the next is not a new step: the open photo changes, the path stays as long.
    private func replacePhoto(_ id: String) {
        walk.back()
        walk.enter(.photo(id: id))
    }

    private func goBack() {
        if case .photo(let id) = walk.current { spot = selection.isEmpty ? id : selection; spotToken += 1 }
        withAnimation(spring) {
            if !walk.back() { back() }
        }
    }

    private func tapped(_ k: Int) {
        guard let next = walk.tapped(k) else { back(); return }
        withAnimation(spring) { walk = next }
    }
}
