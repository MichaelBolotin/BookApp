import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var library = BookLibrary()
    @State private var importing = false
    @State private var settings = false
    @State private var errorMessage: String?
    @State private var errorBook: ReadingBook?

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
                            } else {
                                bookRow(book)
                                    .contextMenu {
                                        if book.state == .failed {
                                            Button("Resume processing", systemImage: "arrow.clockwise") {
                                                library.resume(book.id)
                                            }
                                        }
                                    }
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
            .sheet(item: $errorBook) { book in
                NavigationStack {
                    ScrollView {
                        Text(book.errorMessage ?? "Processing stopped without an error message.")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding()
                    }
                    .navigationTitle("Processing error")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Copy error") {
                                UIPasteboard.general.string = book.errorMessage
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { errorBook = nil }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
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
                    ProgressView(value: book.progress)
                    Text("Preparing \(book.completedChunks) of \(book.totalChunks) batches")
                        .font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Button("View full error") { errorBook = book }
                        .font(.caption).foregroundStyle(.red)
                    Button("Resume processing") { library.resume(book.id) }.font(.caption)
                case .ready:
                    Text("Ready to read").font(.caption).foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
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
                    Text("The key is stored in this device's Keychain. Each book is processed once; resuming uses the current model and instructions for unfinished batches.")
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
            .onAppear { apiKey = SettingsStore.apiKey }
        }
    }
}
