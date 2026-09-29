import SwiftUI
import UniformTypeIdentifiers

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
                                           description: Text("Add an English PDF or paste text, then tap a word to translate it."))
                } else {
                    List {
                        ForEach(library.books) { book in
                            NavigationLink {
                                ReaderView(library: library, bookID: book.id)
                            } label: { bookRow(book) }
                                .contextMenu { detailsButton(for: book) }
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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Paste text", systemImage: "doc.on.clipboard") {
                        do { try library.importPastedText() }
                        catch { errorMessage = error.localizedDescription }
                    }
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
                Text("The book and its saved translations will be removed from this device and iCloud.")
            }
            .alert("Could not add book", isPresented: Binding(
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
                Text("\(book.translatedWordCount) of \(book.wordCount) words translated")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }
}

struct SettingsView: View {
    @ObservedObject var library: BookLibrary
    @Environment(\.dismiss) private var dismiss
    @AppStorage("geminiModel") private var model = AppConfiguration.defaultModel.rawValue
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
                    Text("The key is stored in this device's Keychain. Tap a word to translate it with up to ten neighboring words as context. Long press and drag over words to translate the selected passage. Word translations are reused; passage translations are temporary.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    Text("Importing a PDF or pasting text does not send it to Gemini. A tapped word and its nearby context, or a selected passage, are sent only when you request a translation. Books, word translations, reading progress, and request costs are stored on this device.")
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
            }
        }
    }
}
