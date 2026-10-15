import SwiftUI

/// Organizer's quick add, as the web form has it: one grouped list. The words go in
/// the first row; the server reads them (no AI) and the rows below fill in:
/// a question for any part it is unsure of, then Title, Date, Time, List, and Add.
/// Only what the person changes is sent as an override, so a repeat the words
/// carried is not lost.
struct QuickAddView: View {
    let source: AeroSource

    @State private var text = ""
    @State private var picks: [Int: String] = [:]
    @State private var reading: QuickAddReading?
    @State private var lists: [OrganizerList] = []
    @State private var title = ""
    @State private var date: Date?
    @State private var time: Date?
    @State private var listID = ""
    @State private var edited: Set<String> = []
    @State private var busy = false
    @State private var message = ""

    private struct Ask: Equatable {
        var text: String
        var picks: [Int: String]
    }

    var body: some View {
        Form {
            if !message.isEmpty {
                Section { Text(message) }
            }
            Section {
                TextField("New reminder", text: $text)
                    .submitLabel(.done)
            }
            if reading != nil && !trimmed.isEmpty {
                ForEach(reading?.readings?.questions ?? []) { question in
                    Section(question.title ?? "Which one?") {
                        ForEach(question.options) { option in
                            Button {
                                picks[question.sched] = option.key
                            } label: {
                                HStack {
                                    Text(option.label)
                                    Spacer()
                                    if picks[question.sched] == option.key { Image(systemName: "checkmark") }
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(picks[question.sched] == option.key ? .isSelected : [])
                        }
                    }
                }
                Section {
                    LabeledContent("Title") {
                        TextField("Title", text: edit($title, "title"), axis: .vertical)
                            .multilineTextAlignment(.trailing)
                    }
                    dateRow
                    timeRow
                    Picker("List", selection: edit($listID, "project")) {
                        Text("No list").tag("")
                        ForEach(lists) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    Button("Add") { Task { await add() } }
                        .disabled(busy || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .navigationTitle("New reminder")
        .navigationBarTitleDisplayMode(.inline)
        .task { lists = ((try? await source.organizerBoard().rows) ?? []).filter { $0.kind == "list" } }
        .task(id: Ask(text: text, picks: picks)) { await read() }
        .onChange(of: text) { _ in
            picks = [:]
            edited = []
        }
    }

    // A date is added with one tap and changed with the system picker, as on the web form.
    @ViewBuilder private var dateRow: some View {
        if let current = date {
            DatePicker("Date", selection: edit(Binding(get: { current }, set: { date = $0 }), "date"), displayedComponents: .date)
        } else {
            LabeledContent("Date") { Button("Add a date") { date = Date(); edited.insert("date") } }
        }
    }

    @ViewBuilder private var timeRow: some View {
        if let current = time {
            DatePicker("Time", selection: edit(Binding(get: { current }, set: { time = $0 }), "time"), displayedComponents: .hourAndMinute)
        } else {
            LabeledContent("Time") { Button("Add a time") { time = Date(); edited.insert("time") } }
        }
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A binding that remembers the person changed this row.
    private func edit<T>(_ binding: Binding<T>, _ key: String) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; edited.insert(key) })
    }

    private func read() async {
        guard !trimmed.isEmpty else {
            reading = nil
            return
        }
        try? await Task.sleep(nanoseconds: 250_000_000)   // wait for a pause in typing
        guard !Task.isCancelled, let got = try? await source.understand(trimmed, choose: picks) else { return }
        reading = got
        if !edited.contains("title") { title = got.args?.title ?? "" }
        let stamp = got.args?.due ?? got.args?.start ?? ""
        if !edited.contains("date") { date = Self.day.date(from: String(stamp.prefix(10))) }
        if !edited.contains("time") { time = stamp.count > 10 ? Self.clock.date(from: String(stamp.suffix(5))) : nil }
        if !edited.contains("project") { listID = got.args?.project ?? "" }
    }

    private func add() async {
        busy = true
        defer { busy = false }
        var over: [String: Any] = [:]
        if edited.contains("title") { over["title"] = title }
        if edited.contains("date"), let date { over["date"] = Self.day.string(from: date) }
        if edited.contains("time"), let time { over["time"] = Self.clock.string(from: time) }
        if edited.contains("project") { over["project"] = listID }
        do {
            try await source.quickAdd(trimmed, choose: picks, override: over)
            message = "Added: \(title)"
            text = ""
            reading = nil
        } catch {
            message = "Could not add it. Try again."
        }
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()
}
