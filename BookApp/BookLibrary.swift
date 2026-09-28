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
        for book in books where book.state == .processing { resume(book.id) }
    }

    func resume(_ id: UUID) {
        guard jobs[id] == nil, let book = books.first(where: { $0.id == id }), book.state != .ready else { return }
        jobs[id] = Task { [weak self] in
            await self?.process(id)
            self?.jobs[id] = nil
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
        book.state = .processing
        book.errorMessage = nil
        do {
            try replace(book)
            let translator = GeminiTranslator(apiKey: SettingsStore.apiKey,
                                              model: SettingsStore.model,
                                              instructions: SettingsStore.instructions)
            for pageIndex in book.pages.indices {
                let words = book.pages[pageIndex].words
                for start in stride(from: 0, to: words.count, by: TranslationBatch.wordLimit) {
                    try Task.checkCancellation()
                    if book.pages[pageIndex].completedChunkStarts.contains(start) { continue }
                    let end = min(start + TranslationBatch.wordLimit, words.count)
                    let batch = Array(words[start..<end])
                    let contextStart = max(0, batch[0].location - 300)
                    let last = batch[batch.count - 1]
                    let contextEnd = min((book.pages[pageIndex].text as NSString).length,
                                         last.location + last.length + 300)
                    let context = (book.pages[pageIndex].text as NSString)
                        .substring(with: NSRange(location: contextStart, length: contextEnd - contextStart))
                    let translated = try await translator.translate(words: batch, context: context)
                    try Task.checkCancellation()
                    book.pages[pageIndex].translations += translated.map {
                        TranslationSpan(start: $0.start + start, end: $0.end + start, hebrew: $0.hebrew)
                    }
                    book.pages[pageIndex].completedChunkStarts.append(start)
                    try replace(book) // Durable checkpoint, before sending the next paid request.
                }
            }
            book.state = .ready
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
        return saved.isEmpty ? AppConfiguration.defaultInstructions : saved
    }
}
