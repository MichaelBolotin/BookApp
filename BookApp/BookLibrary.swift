import Foundation
import Combine
import CryptoKit
import Security

@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var books: [ReadingBook] = []
    private var jobs: [UUID: Task<Void, Never>] = [:]

    private let directory: URL

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        books = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReadingBook.self, from: data)
        }.sorted { $0.addedAt > $1.addedAt }
    }

    func importPDF(at url: URL) throws {
        guard !SettingsStore.apiKey.isEmpty else { throw GeminiTranslator.TranslationError.missingKey }
        // File importer URLs are security scoped; consume and copy before the caller releases access.
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard !books.contains(where: { $0.fingerprint == digest }) else { throw LibraryError.duplicate }
        let pages = try PDFImportService.extract(from: url)
        let id = UUID()
        let destination = directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf")
        try data.write(to: destination, options: .atomic)
        let book = ReadingBook(id: id, title: url.deletingPathExtension().lastPathComponent,
                               addedAt: Date(), fingerprint: digest, pages: pages,
                               state: .processing, errorMessage: nil)
        do { try save(book) } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        books.insert(book, at: 0)
        resume(id)
    }

    func resumePending() {
        for candidate in books where candidate.state == .processing && jobs[candidate.id] == nil {
            var book = candidate
            if book.rawResponse != nil {
                resume(book.id) // Reuse the saved response without a network call.
            } else {
                book.state = .failed
                book.errorMessage = "The previous request was interrupted before its result was saved. Its outcome is unknown. Send a new request explicitly if you want to try again."
                try? replace(book)
            }
        }
    }

    func resume(_ id: UUID) {
        guard jobs[id] == nil, let book = books.first(where: { $0.id == id }),
              book.state == .processing else { return }
        jobs[id] = Task { [weak self] in
            await self?.process(id)
            self?.jobs[id] = nil
        }
    }

    func retry(_ id: UUID) {
        guard jobs[id] == nil, var book = books.first(where: { $0.id == id }),
              book.state == .failed else { return }
        if let raw = book.rawResponse {
            book.previousResponses = (book.previousResponses ?? []) + [raw]
        }
        book.rawResponse = nil
        book.errorMessage = nil
        book.state = .processing
        do {
            try replace(book)
            resume(id)
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    func recheckSavedResponse(_ id: UUID) {
        guard jobs[id] == nil, var book = books.first(where: { $0.id == id }),
              book.state == .failed, book.rawResponse != nil else { return }
        book.state = .processing
        do {
            try replace(book)
            resume(id) // process parses the saved response without making an HTTP request.
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    func setPage(_ page: Int, in id: UUID) {
        guard var book = books.first(where: { $0.id == id }), book.pages.indices.contains(page) else { return }
        book.currentPage = page
        try? replace(book)
    }

    func delete(_ id: UUID) {
        jobs[id]?.cancel()
        jobs[id] = nil
        books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf"))
    }

    private func process(_ id: UUID) async {
        guard var book = books.first(where: { $0.id == id }) else { return }
        do {
            let translator = GeminiTranslator(apiKey: SettingsStore.apiKey,
                                              model: SettingsStore.model,
                                              instructions: SettingsStore.instructions)
            if book.rawResponse == nil {
                // Import and interrupted jobs make one request for the entire book.
                let raw = try await translator.requestTranslation(for: book.pages)
                book.rawResponse = raw
                try replace(book) // Keep the paid response before attempting any parsing.
            }
            let translated = try GeminiTranslator.parse(book.rawResponse!, pages: book.pages)
            try Task.checkCancellation()
            for index in book.pages.indices {
                book.pages[index].translations = translated.pages[index]
                book.pages[index].completedChunkStarts = []
            }
            book.state = .ready
            book.errorMessage = translated.translatedWords == translated.totalWords ? nil
                : "\(translated.translatedWords) of \(translated.totalWords) words have a saved translation. Untranslated words remain tappable but show a missing-translation message."
            try replace(book)
        } catch is CancellationError {
            return
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    private func replace(_ book: ReadingBook) throws {
        try save(book)
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
    }

    private func save(_ book: ReadingBook) throws {
        let data = try JSONEncoder().encode(book)
        try data.write(to: directory.appendingPathComponent(book.id.uuidString).appendingPathExtension("json"), options: .atomic)
    }

    enum LibraryError: LocalizedError {
        case duplicate
        var errorDescription: String? { "This PDF is already in your library." }
    }
}

enum SettingsStore {
    private static let keyAccount = "gemini-api-key"
    static var apiKey: String {
        get {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "BookApp",
                                        kSecAttrAccount as String: keyAccount,
                                        kSecReturnData as String: true,
                                        kSecMatchLimit as String: kSecMatchLimitOne]
            var item: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
               let data = item as? Data, let value = String(data: data, encoding: .utf8) {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return AppConfiguration.fallbackAPIKey
        }
        set {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: Bundle.main.bundleIdentifier ?? "BookApp",
                                        kSecAttrAccount as String: keyAccount]
            SecItemDelete(query as CFDictionary)
            let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }
            var attributes = query
            attributes[kSecValueData as String] = Data(value.utf8)
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }
    static var model: AppConfiguration.GeminiModel {
        AppConfiguration.GeminiModel(rawValue: UserDefaults.standard.string(forKey: "geminiModel") ?? "")
            ?? AppConfiguration.defaultModel
    }
    static var instructions: String {
        let saved = UserDefaults.standard.string(forKey: "geminiInstructions") ?? ""
        // The previous default instructed Gemini to omit one item for a two-word phrase.
        if saved.contains("zero-based LOCAL indexes.")
            || saved.contains("translations must contain one entry for EVERY indexed word") {
            return AppConfiguration.defaultInstructions
        }
        return saved.isEmpty ? AppConfiguration.defaultInstructions : saved
    }
}
