import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var library = BookLibrary()
    @State private var importing = false
    @State private var settings = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if library.books.isEmpty {
                    ContentUnavailableView("Your reading library", systemImage: "books.vertical",
                                           description: Text("Add an English PDF to prepare tap-to-translate reading."))
                } else {
                    List {
                        ForEach(library.books) { book in
                            if book.state == .ready {
                                NavigationLink {
                                    ReaderView(library: library, bookID: book.id)
                                } label: { bookRow(book) }
                            } else if book.state == .failed {
                                NavigationLink {
                                    ProcessingFailureView(library: library, bookID: book.id)
                                } label: { bookRow(book) }
                            } else {
                                bookRow(book)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { library.delete(library.books[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("Library")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") { settings = true }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add PDF", systemImage: "plus") { importing = true }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
                do {
                    let url = try result.get()
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                    try library.importPDF(at: url)
                } catch { errorMessage = error.localizedDescription }
            }
            .sheet(isPresented: $settings) {
                SettingsView().onDisappear { library.resumePending() }
            }
            .alert("Could not import PDF", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .task { library.resumePending() }
        }
    }

    private func bookRow(_ book: ReadingBook) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "book.closed.fill")
                .font(.title2).foregroundStyle(.indigo)
                .frame(width: 46, height: 58)
                .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title).font(.headline).lineLimit(2)
                Text("\(book.pages.count) pages").font(.subheadline).foregroundStyle(.secondary)
                switch book.state {
                case .processing:
                    ProgressView()
                    Text("Preparing the entire book in one request")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("View processing error").font(.caption).foregroundStyle(.red)
                case .ready:
                    Text("Ready to read").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProcessingFailureView: View {
    @ObservedObject var library: BookLibrary
    let bookID: UUID

    var body: some View {
        Group {
            if let book = library.books.first(where: { $0.id == bookID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(book.errorMessage ?? "Processing stopped without an error message.")
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if book.state == .failed {
                            Button("Send one new Gemini request") { library.retry(bookID) }
                                .buttonStyle(.borderedProminent)
                            Text("This sends the entire book again and may incur an API charge.")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if book.state == .processing {
                            ProgressView("Preparing the book")
                        } else {
                            Text("Ready to read").foregroundStyle(.green)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Processing error")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Copy error") { UIPasteboard.general.string = book.errorMessage }
                            .disabled(book.errorMessage == nil)
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("geminiModel") private var model = AppConfiguration.defaultModel.rawValue
    @AppStorage("geminiInstructions") private var instructions = AppConfiguration.defaultInstructions
    @State private var apiKey = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Gemini") {
                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Model", selection: $model) {
                        ForEach(AppConfiguration.GeminiModel.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    Text("The key is stored in this device's Keychain. The entire book is sent in one request. A failed request is retried only when you choose to send it again.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Translation instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 260)
                        .accessibilityLabel("Gemini translation instructions")
                    Button("Restore default instructions") { instructions = AppConfiguration.defaultInstructions }
                }
                Section {
                    Text("PDF text is sent to Google's Gemini API during preparation. Translations and reading progress are stored on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { SettingsStore.apiKey = apiKey; dismiss() } }
            .onAppear {
                apiKey = SettingsStore.apiKey
                if instructions.contains("zero-based LOCAL indexes.") {
                    instructions = AppConfiguration.defaultInstructions
                }
            }
        }
    }
}
