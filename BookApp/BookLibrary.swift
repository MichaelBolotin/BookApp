import Foundation
import Combine
import CryptoKit
import Security

@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var books: [ReadingBook] = []
    @Published private(set) var cloudStatus = "Waiting for iCloud sync"

    private let directory: URL
    private let cloud = CloudBookSync()
    private var tombstones: [UUID: Date] = [:]
    private var syncTask: Task<Void, Never>?
    private var syncAgain = false

    init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Books", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        books = files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(ReadingBook.self, from: data)
        }.sorted { $0.addedAt > $1.addedAt }
        for file in files where file.pathExtension == "deleted" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let date = try? JSONDecoder().decode(Date.self, from: data) else { continue }
            tombstones[id] = date
        }
        BackgroundGeminiService.shared.onResult = { [weak self] id in self?.handleResult(id) }
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
                               state: .processing, errorMessage: nil, modifiedAt: Date())
        do { try save(book) } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        books.insert(book, at: 0)
        scheduleCloudSync()
        start(id)
    }

    func resumePending() async {
        let active = await BackgroundGeminiService.shared.activeBookIDs()
        var awaitingTaskRegistration = false
        for candidate in books where candidate.state == .processing {
            var book = candidate
            if BackgroundGeminiService.shared.result(book.id) != nil {
                handleResult(book.id)
            } else if book.rawResponse != nil {
                processSaved(book.id)
            } else if active.contains(book.id) {
                continue
            } else if Date().timeIntervalSince(book.modifiedAt ?? book.addedAt) > 120 {
                book.state = .failed
                book.errorMessage = "The background transfer ended without a saved result. Its remote outcome is unknown. Send a new request explicitly if you want to try again."
                try? replace(book)
            } else {
                awaitingTaskRegistration = true
            }
        }
        if awaitingTaskRegistration {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(125))
                await self?.resumePending()
            }
        }
    }

    func retry(_ id: UUID) {
        if BackgroundGeminiService.shared.result(id) != nil {
            handleResult(id) // Recover a delivered response before considering a paid retry.
            return
        }
        guard var book = books.first(where: { $0.id == id }),
              book.state == .failed else { return }
        if let raw = book.rawResponse {
            book.previousResponses = (book.previousResponses ?? []) + [raw]
        }
        book.rawResponse = nil
        book.translationCost = nil
        book.errorMessage = nil
        book.state = .processing
        do {
            try replace(book)
            start(id)
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    func recheckSavedResponse(_ id: UUID) {
        guard var book = books.first(where: { $0.id == id }),
              book.state == .failed, book.rawResponse != nil else { return }
        book.state = .processing
        do {
            try replace(book)
            processSaved(id) // No HTTP request.
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
        BackgroundGeminiService.shared.cancel(id)
        let date = Date()
        let tombstoneURL = directory.appendingPathComponent(id.uuidString).appendingPathExtension("deleted")
        do {
            try JSONEncoder().encode(date).write(to: tombstoneURL, options: .atomic)
        } catch { return }
        tombstones[id] = date
        books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("json"))
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString).appendingPathExtension("pdf"))
        scheduleCloudSync()
    }

    private func start(_ id: UUID) {
        guard var book = books.first(where: { $0.id == id }) else { return }
        do {
            if book.rawResponse != nil {
                processSaved(id)
                return
            }
            let translator = GeminiTranslator(apiKey: SettingsStore.apiKey,
                                              model: SettingsStore.model,
                                              instructions: SettingsStore.instructions)
            let (request, body) = try translator.makeRequest(for: book.pages)
            book.translationModelID = translator.model.rawValue
            try replace(book)
            try BackgroundGeminiService.shared.enqueue(bookID: id, request: request, body: body)
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    private func handleResult(_ id: UUID) {
        guard let outcome = BackgroundGeminiService.shared.result(id) else { return }
        guard var book = books.first(where: { $0.id == id }) else {
            BackgroundGeminiService.shared.removeResult(id)
            return
        }
        do {
            if let status = outcome.status, (200..<300).contains(status),
               let raw = String(data: outcome.body, encoding: .utf8) {
                book.rawResponse = raw
                book.translationCost = BookTranslationCost.estimate(
                    rawResponse: raw, requestedModel: book.translationModelID)
                try replace(book) // Durable paid response before parsing or removing transfer result.
                BackgroundGeminiService.shared.removeResult(id)
                processSaved(id)
            } else {
                book.state = .failed
                if let status = outcome.status {
                    book.errorMessage = GeminiTranslator.responseError(
                        status: status, data: outcome.body,
                        modelID: book.translationModelID ?? "unknown",
                        wordCount: book.wordCount).localizedDescription
                } else {
                    book.errorMessage = outcome.error ?? "Background transfer ended without an HTTP response."
                }
                try replace(book)
                BackgroundGeminiService.shared.removeResult(id)
            }
        } catch {
            book.state = .failed
            book.errorMessage = "Could not save the Gemini result: \(error.localizedDescription)"
            try? replace(book)
        }
    }

    private func processSaved(_ id: UUID) {
        guard var book = books.first(where: { $0.id == id }), let raw = book.rawResponse else { return }
        do {
            if book.translationCost == nil {
                book.translationCost = BookTranslationCost.estimate(
                    rawResponse: raw, requestedModel: book.translationModelID)
            }
            let translated = try GeminiTranslator.parse(raw, pages: book.pages)
            for index in book.pages.indices {
                book.pages[index].translations = translated.pages[index]
                book.pages[index].completedChunkStarts = []
            }
            book.state = .ready
            book.errorMessage = translated.translatedWords == translated.totalWords ? nil
                : "\(translated.translatedWords) of \(translated.totalWords) words have a saved translation. Untranslated words remain tappable but show a missing-translation message."
            try replace(book)
        } catch {
            book.state = .failed
            book.errorMessage = error.localizedDescription
            try? replace(book)
        }
    }

    private func replace(_ value: ReadingBook) throws {
        var book = value
        book.modifiedAt = Date()
        try save(book)
        guard let index = books.firstIndex(where: { $0.id == book.id }) else { return }
        books[index] = book
        scheduleCloudSync()
    }

    private func save(_ book: ReadingBook) throws {
        let data = try JSONEncoder().encode(book)
        try data.write(to: directory.appendingPathComponent(book.id.uuidString).appendingPathExtension("json"), options: .atomic)
    }

    func scheduleCloudSync() {
        guard syncTask == nil else { syncAgain = true; return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await self?.syncCloud()
            self?.syncTask = nil
            if self?.syncAgain == true {
                self?.syncAgain = false
                self?.scheduleCloudSync()
            }
        }
    }

    func syncCloud() async {
        cloudStatus = "Syncing with iCloud…"
        do {
            let remote = try await cloud.fetchAll()
            var remoteIDs = Set<UUID>()
            for item in remote {
                remoteIDs.insert(item.id)
                if let tombstone = tombstones[item.id], tombstone >= item.modifiedAt {
                    try await cloud.delete(item.id, at: tombstone)
                    continue
                }
                let local = books.first { $0.id == item.id }
                if local?.state == .processing { continue }
                if item.deleted {
                    if local == nil || item.modifiedAt >= (local?.modifiedAt ?? local?.addedAt ?? .distantPast) {
                        books.removeAll { $0.id == item.id }
                        try? FileManager.default.removeItem(at: bookURL(item.id, extension: "json"))
                        try? FileManager.default.removeItem(at: bookURL(item.id, extension: "pdf"))
                        tombstones[item.id] = item.modifiedAt
                        try? JSONEncoder().encode(item.modifiedAt).write(
                            to: bookURL(item.id, extension: "deleted"), options: .atomic)
                    } else if let local {
                        try await cloud.upload(local, snapshotURL: bookURL(item.id, extension: "json"),
                                               pdfURL: bookURL(item.id, extension: "pdf"))
                    }
                    continue
                }
                if local == nil || item.modifiedAt > (local?.modifiedAt ?? local?.addedAt ?? .distantPast) {
                    guard let snapshot = item.snapshot, let pdf = item.pdf,
                          let imported = try? JSONDecoder().decode(ReadingBook.self, from: snapshot) else { continue }
                    try snapshot.write(to: bookURL(item.id, extension: "json"), options: .atomic)
                    try pdf.write(to: bookURL(item.id, extension: "pdf"), options: .atomic)
                    books.removeAll { $0.id == item.id }
                    books.append(imported)
                    books.sort { $0.addedAt > $1.addedAt }
                } else if let local {
                    try await cloud.upload(local, snapshotURL: bookURL(item.id, extension: "json"),
                                           pdfURL: bookURL(item.id, extension: "pdf"))
                }
            }
            for book in books where !remoteIDs.contains(book.id) && book.state != .processing {
                try await cloud.upload(book, snapshotURL: bookURL(book.id, extension: "json"),
                                       pdfURL: bookURL(book.id, extension: "pdf"))
            }
            for (id, date) in tombstones where !remoteIDs.contains(id) {
                try await cloud.delete(id, at: date)
            }
            cloudStatus = "iCloud synced"
        } catch {
            cloudStatus = "iCloud sync unavailable: \(error.localizedDescription)"
        }
    }

    private func bookURL(_ id: UUID, extension ext: String) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(ext)
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
