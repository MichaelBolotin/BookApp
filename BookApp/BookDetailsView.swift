import SwiftUI

struct BookDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: BookLibrary
    let bookID: UUID

    var body: some View {
        NavigationStack {
            if let book = library.books.first(where: { $0.id == bookID }) {
                let cost = book.translationCost ?? book.rawResponse.flatMap {
                    BookTranslationCost.estimate(rawResponse: $0,
                        requestedModel: book.translationModelID, at: book.addedAt)
                }
                let previousCosts = (book.previousResponses ?? []).compactMap {
                    BookTranslationCost.estimate(rawResponse: $0, requestedModel: nil, at: book.addedAt)
                }
                let wordCosts = (book.savedWordTranslations ?? []).compactMap(\.cost)
                let allCosts = ([cost].compactMap { $0 } + previousCosts + wordCosts)
                Form {
                    Section("Book") {
                        LabeledContent("Title", value: book.title)
                        LabeledContent("Pages", value: "\(book.pages.count)")
                        LabeledContent("Translated words", value: "\(book.translatedWordCount) of \(book.wordCount)")
                    }
                    Section("Translation cost") {
                        if !allCosts.isEmpty {
                            LabeledContent("Translation requests", value: "\((book.savedWordTranslations ?? []).count + (cost == nil ? 0 : 1) + (book.previousResponses ?? []).count)")
                            LabeledContent("Input tokens", value: allCosts.reduce(0) { $0 + $1.inputTokens }.formatted())
                            LabeledContent("Output tokens", value: allCosts.reduce(0) { $0 + $1.outputTokens }.formatted())
                            LabeledContent("Thinking tokens", value: allCosts.reduce(0) { $0 + $1.thoughtTokens }.formatted())
                            LabeledContent("Estimated paid cost",
                                           value: String(format: "$%.6f", allCosts.reduce(0) { $0 + $1.estimatedUSD }))
                            Text("Cumulative estimate using each model's Standard paid rate when its request was processed, including thinking tokens. Your actual bill may be zero on a free tier or differ with discounts and taxes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        let unpriced = (book.savedWordTranslations ?? []).count - wordCosts.count
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
            }
        }
    }
}
