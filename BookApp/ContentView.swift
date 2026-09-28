import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var library = BookLibrary()
    @State private var importing = false
    @State private var settings = false
    @State private var errorMessage: String?
    @State private var deletionIDs: [UUID] = []
    @State private var detailBook: ReadingBook?

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
                                    .contextMenu { detailsButton(for: book) }
                            } else if book.state == .failed {
                                NavigationLink {
                                    ProcessingFailureView(library: library, bookID: book.id)
                                } label: { bookRow(book) }
                                    .contextMenu { detailsButton(for: book) }
                            } else {
                                bookRow(book)
                                    .contextMenu { detailsButton(for: book) }
                            }
                        }
                        .onDelete { offsets in
                            deletionIDs = offsets.map { library.books[$0].id }
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
                SettingsView(library: library).onDisappear { Task { await library.resumePending() } }
            }
            .sheet(item: $detailBook) { book in
                BookDetailsView(library: library, bookID: book.id)
            }
            .confirmationDialog(
                deletionIDs.count == 1 ? "Delete this book?" : "Delete these books?",
                isPresented: Binding(
                    get: { !deletionIDs.isEmpty },
                    set: { if !$0 { deletionIDs = [] } }
                ), titleVisibility: .visible
            ) {
                Button("Delete permanently", role: .destructive) {
                    for id in deletionIDs { library.delete(id) }
                    deletionIDs = []
                }
            } message: {
                Text("The PDF and its saved translations will be removed from this device and iCloud.")
            }
            .alert("Could not import PDF", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) { Button("OK", role: .cancel) {} } message: { Text(errorMessage ?? "") }
            .task {
                await library.resumePending()
                library.scheduleCloudSync()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await library.resumePending(); library.scheduleCloudSync() }
                }
            }
        }
    }

    private func detailsButton(for book: ReadingBook) -> some View {
        Button("Book details", systemImage: "info.circle") { detailBook = book }
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
                    if book.translatedWordCount < book.wordCount {
                        Text("\(book.translatedWordCount) of \(book.wordCount) words translated")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("Ready to read").font(.caption).foregroundStyle(.green)
                    }
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
                        if let raw = book.rawResponse {
                            Button("Copy saved Gemini response") { UIPasteboard.general.string = raw }
                                .buttonStyle(.bordered)
                            if book.state == .failed {
                                Button("Check saved response again — free") {
                                    library.recheckSavedResponse(bookID)
                                }
                                .buttonStyle(.bordered)
                                Text("This checks the saved response on your iPhone without contacting Gemini.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if let earlier = book.previousResponses {
                            ForEach(earlier.indices, id: \.self) { index in
                                Button("Copy earlier Gemini response \(index + 1)") {
                                    UIPasteboard.general.string = earlier[index]
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        if book.state == .failed {
                            if book.errorMessage?.contains("HTTP 503:") == true {
                                Text("Gemini is temporarily overloaded. Wait and try later, or choose another model below. No translation was returned or saved.")
                                    .foregroundStyle(.secondary)
                            }
                            Text("This book has an earlier whole-book processing error. Its saved response can be checked without another API request.")
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
    @ObservedObject var library: BookLibrary
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
                    Text("The key is stored in this device's Keychain. Each new word you tap sends only that word and up to ten neighboring words on either side. Saved translations are reused without another request.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Legacy whole-book instructions") {
                    TextEditor(text: $instructions)
                        .frame(minHeight: 260)
                        .accessibilityLabel("Gemini translation instructions")
                    Button("Restore default instructions") { instructions = AppConfiguration.defaultInstructions }
                }
                Section {
                    Text("Importing a PDF does not send it to Gemini. A tapped word and its nearby context are sent when you request its translation. Saved translations and reading progress are stored on this device.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("iCloud") {
                    Text(library.cloudStatus)
                    Button("Sync now") { library.scheduleCloudSync() }
                        .disabled(!AppConfiguration.cloudKitEnabled)
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { SettingsStore.apiKey = apiKey; dismiss() } }
            .onAppear {
                apiKey = SettingsStore.apiKey
                if instructions.contains("zero-based LOCAL indexes.")
                    || instructions.contains("translations must contain one entry for EVERY indexed word") {
                    instructions = AppConfiguration.defaultInstructions
                }
            }
        }
    }
}
