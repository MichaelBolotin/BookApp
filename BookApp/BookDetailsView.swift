import SwiftUI
import UniformTypeIdentifiers

struct BookDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: BookLibrary
    let bookID: UUID
    @State private var importingChapter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            if let book = library.books.first(where: { $0.id == bookID }) {
                let wordCosts = (book.savedWordTranslations ?? []).compactMap(\.cost)
                let historicalCosts = book.historicalCosts ?? []
                let allCosts = historicalCosts + wordCosts + (book.sentenceTranslationCosts ?? [])
                let requestCount = (book.savedWordTranslations ?? []).count
                    + (book.historicalRequestCount ?? 0) + (book.sentenceRequestCount ?? 0)
                Form {
                    Section("Book") {
                        LabeledContent("Title", value: book.title)
                        LabeledContent("Pages", value: "\(book.pages.count)")
                        LabeledContent("Translated words", value: "\(book.translatedWordCount) of \(book.wordCount)")
                    }
                    Section("Add a chapter") {
                        Button("Add PDF to this book", systemImage: "doc.badge.plus") {
                            importingChapter = true
                        }
                        Button("Append copied text", systemImage: "doc.on.clipboard") {
                            do { try library.appendPastedText(to: bookID) }
                            catch { importError = error.localizedDescription }
                        }
                        Text("New pages are added at the end. Existing pages, translations, and reading position are kept.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Section("Translation cost") {
                        if requestCount > 0 {
                            LabeledContent("Translation requests", value: "\(requestCount)")
                        }
                        if !allCosts.isEmpty {
                            LabeledContent("Input tokens", value: allCosts.reduce(0) { $0 + $1.inputTokens }.formatted())
                            LabeledContent("Output tokens", value: allCosts.reduce(0) { $0 + $1.outputTokens }.formatted())
                            LabeledContent("Thinking tokens", value: allCosts.reduce(0) { $0 + $1.thoughtTokens }.formatted())
                            LabeledContent("Estimated paid cost",
                                           value: String(format: "$%.6f", allCosts.reduce(0) { $0 + $1.estimatedUSD }))
                            Text("Cumulative estimate using each model's Standard paid rate when its request was processed, including thinking tokens. Your actual bill may be zero on a free tier or differ with discounts and taxes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        let unpriced = requestCount - allCosts.count
                        if unpriced > 0 {
                            Text("\(unpriced) request(s) did not provide usable usage or pricing data and are excluded from this estimate.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if allCosts.isEmpty {
                            Text("No priced translation requests yet. Usage and model pricing are required for an estimate.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("iCloud") {
                        Text(library.cloudStatus)
                    }
                }
                .navigationTitle("Book details")
                .toolbar { Button("Done") { dismiss() } }
                .fileImporter(isPresented: $importingChapter, allowedContentTypes: [.pdf]) { result in
                    do {
                        let url = try result.get()
                        let accessing = url.startAccessingSecurityScopedResource()
                        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                        try library.appendPDF(at: url, to: bookID)
                    } catch { importError = error.localizedDescription }
                }
                .alert("Could not add chapter", isPresented: Binding(
                    get: { importError != nil }, set: { if !$0 { importError = nil } }
                )) { Button("OK", role: .cancel) {} } message: { Text(importError ?? "") }
            }
        }
    }
}
