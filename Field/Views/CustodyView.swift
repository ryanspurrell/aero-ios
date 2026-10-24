import SwiftUI
import UIKit

/// The chain-of-custody sheet, made from the cards, and the handovers behind it. Rules: Part F of FieldSample.lean (`Handover`, `Link`, `Valid`,
/// `valid_append`, `valid_times_sorted`). A handover that does not follow the last one is refused with its reason and nothing is changed. The sheet
/// is shown here and leaves the phone only when the person taps share.
struct CustodyView: View {
    @EnvironmentObject private var store: FieldStore
    @State private var fromName = ""
    @State private var toName = ""
    @State private var time = Date()
    @State private var problem: String?
    @State private var pdf: PDFItem?

    struct PDFItem: Identifiable { let id = UUID(); let url: URL }

    private var last: Handover? { store.data.handovers.last }

    var body: some View {
        let text = store.sheet()
        FieldPage {
            FieldHeader(title: "Chain of custody", subtitle: "Made from your cards. Nothing is sent.")
            FieldCard(title: "Handovers") {
                if store.data.handovers.isEmpty { FieldNote("No handovers yet. Add one each time the filters change hands.") }
                ForEach(Array(store.data.handovers.enumerated()), id: \.offset) { _, h in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(FieldWording.name(h.giver, store.data.people) + " to " + FieldWording.name(h.taker, store.data.people))
                            .ft(Look.Size.rowTitle, style: .body).foregroundStyle(Look.Palette.fg)
                        Text(FieldClock.dateTime(h.time)).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.soft)
                    }
                    .accessibilityElement(children: .combine)
                }
                if last == nil {
                    FieldInput(label: "From", text: $fromName, prompt: store.practice ? "For example Person 1" : "Who has them now")
                } else if let last {
                    FieldNote("From " + FieldWording.name(last.taker, store.data.people) + ", who took them last.")
                }
                FieldInput(label: "To", text: $toName, prompt: store.practice ? "For example Person 2" : "Who takes them")
                DatePicker("Time", selection: $time).ft(Look.Size.calm, style: .body)
                if let problem { Text(problem).ft(Look.Size.calm, style: .body).foregroundStyle(Look.Palette.now).fixedSize(horizontal: false, vertical: true) }
                FieldButtonRow {
                    FieldButton(title: "Add handover", symbol: "arrow.right.circle", enabled: canAdd, action: add)
                    if last != nil { FieldButton(title: "Undo last", symbol: "arrow.uturn.backward", tint: .plain) { store.removeLastHandover(); problem = nil } }
                }
            }
            FieldCard(title: "The sheet") {
                Text(text).ft(Look.Size.itemMeta, style: .footnote).foregroundStyle(Look.Palette.fg).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                FieldButtonRow {
                    ShareLink(item: text) {
                        Label("Share as text", systemImage: "square.and.arrow.up").ft(Look.Size.extra, style: .body)
                            .foregroundStyle(Look.Palette.ink).frame(maxWidth: .infinity, minHeight: Look.Space.sizeControl)
                            .background(RoundedRectangle(cornerRadius: Look.Bubble.radiusChip, style: .continuous).fill(Look.Palette.accent))
                    }
                    FieldButton(title: "Share as PDF", symbol: "doc.richtext", tint: .hue("accent")) { makePDF(text) }
                }
            }
        }
        .sheet(item: $pdf) { item in ActivityView(items: [item.url], cleanup: item.url).presentationDetents([.medium, .large]) }
    }

    private var canAdd: Bool {
        !toName.trimmingCharacters(in: .whitespaces).isEmpty && (last != nil || !fromName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func add() {
        let t = FieldClock.minutes(time)
        let giver = last?.taker ?? store.person(named: fromName)
        let taker = store.person(named: toName)
        if let p = store.addHandover(Handover(giver: giver, taker: taker, time: t)) {
            problem = FieldWording.problem(p, people: store.data.people)
        } else {
            problem = nil; fromName = ""; toName = ""; time = Date()
        }
    }

    private func makePDF(_ text: String) {
        let data = PDFSheet.data(text)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("custody-sheet.pdf")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            pdf = PDFItem(url: url)
        } catch {
            problem = "The PDF could not be made."
        }
    }
}

/// The sheet as a PDF, drawn from the text. No fonts or pictures from anywhere else.
enum PDFSheet {
    static func data(_ text: String) -> Data {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let formatter = UISimpleTextPrintFormatter(text: text)
        formatter.font = UIFont.systemFont(ofSize: 11)
        formatter.perPageContentInsets = UIEdgeInsets(top: 54, left: 54, bottom: 54, right: 54)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: page), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: page), forKey: "printableRect")
        let out = NSMutableData()
        UIGraphicsBeginPDFContextToData(out, page, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: max(renderer.numberOfPages, 1)))
        for i in 0..<max(renderer.numberOfPages, 1) {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: i, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return out as Data
    }
}
