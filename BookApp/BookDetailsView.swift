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
                Form {
                    Section("Book") {
                        LabeledContent("Title", value: book.title)
                        LabeledContent("Pages", value: "\(book.pages.count)")
                        LabeledContent("Translated words", value: "\(book.translatedWordCount) of \(book.wordCount)")
                    }
                    Section("Translation cost") {
                        if let cost {
                            LabeledContent("Model", value: cost.modelID)
                            LabeledContent("Input tokens", value: cost.inputTokens.formatted())
                            LabeledContent("Output tokens", value: cost.outputTokens.formatted())
                            LabeledContent("Thinking tokens", value: cost.thoughtTokens.formatted())
                            LabeledContent("Estimated paid cost",
                                           value: String(format: "$%.6f", cost.estimatedUSD))
                            Text("Estimate using Google's Standard paid rates when processed: $\(cost.inputUSDPerMillion.formatted()) per million input tokens and $\(cost.outputUSDPerMillion.formatted()) per million output tokens, including thinking. Your actual bill may be zero on a free tier or differ with discounts and taxes.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        if !previousCosts.isEmpty {
                            LabeledContent("Earlier saved responses", value: "\(previousCosts.count)")
                            LabeledContent("Estimated total including earlier responses",
                                           value: String(format: "$%.6f",
                                            (cost?.estimatedUSD ?? 0) + previousCosts.reduce(0) { $0 + $1.estimatedUSD }))
                        }
                        if cost == nil && previousCosts.isEmpty {
                            Text("Cost unavailable: this request did not return token usage, or the model used by an older book is unknown.")
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
