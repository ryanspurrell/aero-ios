import SwiftUI

/// The chat list: the server decides which rooms, their order, their headings,
/// their unread counts and which headings are folded; this only draws them.
/// A chat's own title and newest line are opened on the device from sealed
/// messages, which is not built yet, so a row names the kind of chat.
struct ChatListView: View {
    let source: AeroSource

    @State private var view: RoomsView?
    @State private var folded: Set<String> = []
    @State private var failed = false

    var body: some View {
        List {
            if failed {
                Section {
                    Text("Can't reach Aero")
                    Button("Try again") { Task { await load() } }
                }
            }
            ForEach(view?.sections ?? []) { section in
                if !section.rooms.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: expanded(section.id)) {
                            ForEach(section.rooms, id: \.self) { id in
                                if let room = view?.rooms.first(where: { $0.id == id }) { row(room) }
                            }
                        } label: {
                            Text(heading(section)).font(.headline)
                        }
                    }
                }
            }
        }
        .navigationTitle("Chats")
        .task { await load() }
        .refreshable { await load() }
    }

    private func row(_ room: Room) -> some View {
        HStack {
            if room.pinned == true {
                Image(systemName: "pin.fill").foregroundStyle(.secondary).accessibilityLabel("Pinned")
            }
            Text(name(room))
            Spacer()
            if let unread = room.unread, unread > 0 {
                Text("\(unread)")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
                    .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                    .accessibilityLabel("\(unread) unread")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func name(_ room: Room) -> String {
        switch room.kind {
        case "agent": return (room.agent ?? "").capitalized
        case "manager": return (room.manager ?? "").capitalized
        default: return "Chat"
        }
    }

    private func heading(_ section: RoomSection) -> String {
        if let name = section.name, !name.isEmpty { return name }
        return section.kind == "private" ? "Locked" : "Chats"
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(get: { !folded.contains(id) },
                set: { if $0 { folded.remove(id) } else { folded.insert(id) } })
    }

    private func load() async {
        do {
            let got = try await source.rooms(as: "fingus")
            view = got
            folded = Set(got.sections.filter { $0.folded == true }.map(\.id))
            failed = false
        } catch {
            failed = true
        }
    }
}
