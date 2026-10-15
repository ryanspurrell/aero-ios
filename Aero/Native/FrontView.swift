import SwiftUI

/// The front (layout C): what she was in the middle of, what is due today, the
/// door to her chats, and one large Talk button that stays at the bottom.
/// A section with nothing to show is not drawn, and no section has a filler
/// sentence. The face is not drawn yet.
struct FrontView: View {
    let source: AeroSource
    /// Opens the call. Voice is not built, so the app passes nothing yet.
    var onTalk: () -> Void

    @State private var underway: [UnderwayItem] = []
    @State private var today: OrganizerTile?
    @State private var unread = 0
    @State private var failed = false

    var body: some View {
        List {
            if failed {
                Section {
                    Text("Can't reach Aero")
                    Button("Try again") { Task { await load() } }
                }
            }
            if !underway.isEmpty {
                Section("Carry on") {
                    ForEach(underway) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title ?? "Something")
                            Text(detail(item)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            Section("Tonight") {
                NavigationLink(value: Route.quickAdd) {
                    LabeledContent(today?.name ?? "Add a reminder", value: today?.count.map(String.init) ?? "")
                }
            }
            Section {
                NavigationLink(value: Route.chats) {
                    LabeledContent("Chats", value: unread > 0 ? "\(unread) unread" : "")
                }
            }
        }
        .navigationTitle("Aero")
        .safeAreaInset(edge: .bottom) {
            Button(action: onTalk) {
                Label("Talk", systemImage: "mic.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            .padding(.bottom, 8)
            .accessibilityHint("Starts a spoken conversation")
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func detail(_ item: UnderwayItem) -> String {
        var parts: [String] = []
        if let left = item.left, left > 0 {
            parts.append(RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: left), relativeTo: Date()))
        }
        if let why = item.why ?? item.says, !why.isEmpty { parts.append(why) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        var down = false
        do { underway = try await source.underway() } catch { down = true }
        do { today = try await source.organizerBoard().tiles.first { $0.id == "today" } } catch { down = true }
        do { unread = try await source.rooms(as: "fingus").unread ?? 0 } catch { down = true }
        failed = down
    }
}
