import Foundation
import Combine
import CryptoKit
import Security

/// Reads old snapshot metadata once; it cannot start the former whole-book workflow.
private struct LegacyBookUsage: Decodable {
    let state: String?
    let rawResponse: String?
    let previousResponses: [String]?
    let translationModelID: String?
    let translationCost: BookTranslationCost?
}

@MainActor
final class BookLibrary: ObservableObject {
    @Published private(set) var books: [ReadingBook] = []
    @Published private(set) var cloudStatus = AppConfiguration.cloudKitEnabled
        ? "Waiting for iCloud sync" : "iCloud sync is not enabled in this build. Books stay on this device."

    private let directory: URL
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
            return Self.decodeBook(data)
        }.sorted { $0.addedAt > $1.addedAt }
        for book in books {
            if let data = try? Data(contentsOf: bookURL(book.id, extension: "json")),
               let legacy = try? JSONDecoder().decode(LegacyBookUsage.self, from: data),
               legacy.state != nil {
                if legacy.state == "processing" { BackgroundGeminiService.shared.cancel(book.id) }
                // Re-encode without the old response and processing fields after extracting usage.
                try? save(book)
            }
        }
        for file in files where file.pathExtension == "deleted" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let data = try? Data(contentsOf: file),
                  let date = try? JSONDecoder().decode(Date.self, from: data) else { continue }
            tombstones[id] = date
        }
        BackgroundGeminiService.shared.onResult = { [weak self] id in self?.handleResult(id) }
    }

    private static func decodeBook(_ data: Data) -> ReadingBook? {
        guard var book = try? JSONDecoder().decode(ReadingBook.self, from: data) else { return nil }
        // A saved two-word phrase cannot be assigned accurately to either single word.
        for pageIndex in book.pages.indices {
            book.pages[pageIndex].translations.removeAll { $0.start != $0.end }
        }
        if let legacy = try? JSONDecoder().decode(LegacyBookUsage.self, from: data) {
            var costs = book.historicalCosts ?? []
            if let raw = legacy.rawResponse {
                if let cost = legacy.translationCost ?? BookTranslationCost.estimate(
                    rawResponse: raw, requestedModel: legacy.translationModelID, at: book.addedAt) {
                    costs.append(cost)
                }
            } else if let cost = legacy.translationCost {
                costs.append(cost)
            }
            for raw in legacy.previousResponses ?? [] {
                if let cost = BookTranslationCost.estimate(rawResponse: raw,
                    requestedModel: nil, at: book.addedAt) {
                    costs.append(cost)
                }
            }
            let count = (legacy.rawResponse == nil && legacy.translationCost == nil ? 0 : 1)
                + (legacy.previousResponses ?? []).count
            if count > 0 {
                book.historicalCosts = costs
                book.historicalRequestCount = (book.historicalRequestCount ?? 0) + count
            }
        }
        return book
    }

    func importPDF(at url: URL) throws {
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
                               modifiedAt: Date())
        do { try save(book) } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        books.insert(book, at: 0)
        scheduleCloudSync()
    }

    func requestWord(_ wordIndex: Int, on pageIndex: Int, in id: UUID, retry: Bool = false) {
        guard var book = books.first(where: { $0.id == id }),
              book.pages.indices.contains(pageIndex),
              book.pages[pageIndex].words.indices.contains(wordIndex),
              !book.pages[pageIndex].translations.contains(where: { $0.contains(wordIndex) }),
              !(book.pendingWordTranslations ?? []).contains(where: {
                  $0.pageIndex == pageIndex && $0.wordIndex == wordIndex
              }) else { return }
        // A saved response that failed validation is never silently billed again.
        if !retry && ((book.savedWordTranslations ?? []).contains(where: {
            $0.pageIndex == pageIndex && $0.wordIndex == wordIndex
        }) || (book.wordTranslationFailures ?? []).contains(where: {
            $0.pageIndex == pageIndex && $0.wordIndex == wordIndex
        })) { return }
        do {
            let translator = OnDemandWordTranslator(apiKey: SettingsStore.apiKey, model: SettingsStore.model)
            let (request, body) = try translator.makeRequest(
                pages: book.pages, pageIndex: pageIndex, wordIndex: wordIndex)
            let pending = PendingWordTranslation(id: UUID(), pageIndex: pageIndex,
                                                 wordIndex: wordIndex, modelID: translator.model.rawValue,
                                                 startedAt: Date())
            book.wordTranslationFailures?.removeAll { $0.pageIndex == pageIndex && $0.wordIndex == wordIndex }
            book.pendingWordTranslations = (book.pendingWordTranslations ?? []) + [pending]
            try replace(book)
            do {
                try BackgroundGeminiService.shared.enqueue(bookID: pending.id, request: request, body: body)
            } catch {
                recordWordFailure(error.localizedDescription, for: pending, in: id)
            }
        } catch {
            let pending = PendingWordTranslation(id: UUID(), pageIndex: pageIndex,
                                                 wordIndex: wordIndex, modelID: SettingsStore.model.rawValue,
                                                 startedAt: Date())
            recordWordFailure(error.localizedDescription, for: pending, in: id)
        }
    }

    private func recordWordFailure(_ message: String, for pending: PendingWordTranslation, in id: UUID) {
        guard var book = books.first(where: { $0.id == id }) else { return }
        book.pendingWordTranslations?.removeAll { $0.id == pending.id }
        book.wordTranslationFailures?.removeAll {
            $0.pageIndex == pending.pageIndex && $0.wordIndex == pending.wordIndex
        }
        book.wordTranslationFailures = (book.wordTranslationFailures ?? []) + [
            WordTranslationFailure(pageIndex: pending.pageIndex,
                                   wordIndex: pending.wordIndex, message: message)
        ]
        try? replace(book)
    }

    private func handleWordResult(_ pending: PendingWordTranslation, in id: UUID) {
        guard let outcome = BackgroundGeminiService.shared.result(pending.id),
              var book = books.first(where: { $0.id == id }) else { return }
        guard let status = outcome.status, (200..<300).contains(status),
              let raw = String(data: outcome.body, encoding: .utf8) else {
            let message = outcome.status.map {
                OnDemandWordTranslator.responseError(status: $0, data: outcome.body,
                    modelID: pending.modelID).localizedDescription
            } ?? outcome.error ?? "The translation transfer ended without a response. Retry only if you want to send a new request."
            recordWordFailure(message, for: pending, in: id)
            BackgroundGeminiService.shared.removeResult(pending.id)
            return
        }
        if !(book.savedWordTranslations ?? []).contains(where: { $0.requestID == pending.id }) {
            let saved = SavedWordTranslation(requestID: pending.id, pageIndex: pending.pageIndex,
                wordIndex: pending.wordIndex, modelID: pending.modelID, rawResponse: raw,
                cost: BookTranslationCost.estimate(rawResponse: raw, requestedModel: pending.modelID))
            book.savedWordTranslations = (book.savedWordTranslations ?? []) + [saved]
        }
        do {
            try replace(book) // Preserve the paid response and usage before decoding it.
            BackgroundGeminiService.shared.removeResult(pending.id)
            do {
                let hebrew = try OnDemandWordTranslator.parse(raw)
                book.pages[pending.pageIndex].translations.append(
                    TranslationSpan(start: pending.wordIndex, end: pending.wordIndex, hebrew: hebrew))
                book.pendingWordTranslations?.removeAll { $0.id == pending.id }
                try replace(book)
            } catch {
                recordWordFailure(error.localizedDescription, for: pending, in: id)
            }
        } catch {
            // Keep the transfer result for reconciliation if the durable write failed.
        }
    }

    func resumePending() async {
        let active = await BackgroundGeminiService.shared.activeBookIDs()
        var awaitingTaskRegistration = false
        for candidate in books {
            for pending in candidate.pendingWordTranslations ?? [] {
                if BackgroundGeminiService.shared.result(pending.id) != nil {
                    handleWordResult(pending, in: candidate.id)
                } else if let saved = candidate.savedWordTranslations?.first(where: { $0.requestID == pending.id }) {
                    do {
                        let hebrew = try OnDemandWordTranslator.parse(saved.rawResponse)
                        if var current = books.first(where: { $0.id == candidate.id }) {
                            if !current.pages[pending.pageIndex].translations.contains(where: { $0.contains(pending.wordIndex) }) {
                                current.pages[pending.pageIndex].translations.append(
                                    TranslationSpan(start: pending.wordIndex, end: pending.wordIndex, hebrew: hebrew))
                            }
                            current.pendingWordTranslations?.removeAll { $0.id == pending.id }
                            try replace(current)
                        }
                    } catch {
                        recordWordFailure(error.localizedDescription, for: pending, in: candidate.id)
                    }
                } else if active.contains(pending.id) {
                    continue
                } else if Date().timeIntervalSince(pending.startedAt) > 120 {
                    recordWordFailure("The background transfer ended without a saved result. Its outcome is unknown; retry only if you want to send a new request.", for: pending, in: candidate.id)
                } else {
                    awaitingTaskRegistration = true
                }
            }
        }
        if awaitingTaskRegistration {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(125))
                await self?.resumePending()
            }
        }
    }

    func setPage(_ page: Int, in id: UUID) {
        guard var book = books.first(where: { $0.id == id }), book.pages.indices.contains(page) else { return }
        book.currentPage = page
        try? replace(book)
    }

    func delete(_ id: UUID) {
        if let book = books.first(where: { $0.id == id }) {
            for pending in book.pendingWordTranslations ?? [] {
                BackgroundGeminiService.shared.cancel(pending.id)
            }
        }
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

    private func handleResult(_ id: UUID) {
        if let book = books.first(where: { ($0.pendingWordTranslations ?? []).contains { $0.id == id } }),
           let pending = book.pendingWordTranslations?.first(where: { $0.id == id }) {
            handleWordResult(pending, in: book.id)
            return
        }
        // An old transfer may finish after migration; it must never restart translation.
        BackgroundGeminiService.shared.removeResult(id)
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
        guard AppConfiguration.cloudKitEnabled else { return }
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
        #if CLOUDKIT_ENABLED
        cloudStatus = "Syncing with iCloud…"
        do {
            // Do not construct CKContainer in builds without the iCloud entitlement.
            let cloud = CloudBookSync()
            let remote = try await cloud.fetchAll()
            var remoteIDs = Set<UUID>()
            for item in remote {
                remoteIDs.insert(item.id)
                if let tombstone = tombstones[item.id], tombstone >= item.modifiedAt {
                    try await cloud.delete(item.id, at: tombstone)
                    continue
                }
                let local = books.first { $0.id == item.id }
                if !(local?.pendingWordTranslations ?? []).isEmpty { continue }
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
                          let imported = Self.decodeBook(snapshot) else { continue }
                    try JSONEncoder().encode(imported).write(to: bookURL(item.id, extension: "json"), options: .atomic)
                    try pdf.write(to: bookURL(item.id, extension: "pdf"), options: .atomic)
                    books.removeAll { $0.id == item.id }
                    books.append(imported)
                    books.sort { $0.addedAt > $1.addedAt }
                } else if let local {
                    try await cloud.upload(local, snapshotURL: bookURL(item.id, extension: "json"),
                                           pdfURL: bookURL(item.id, extension: "pdf"))
                }
            }
            for book in books where !remoteIDs.contains(book.id)
                && (book.pendingWordTranslations ?? []).isEmpty {
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
        #else
        cloudStatus = "iCloud sync is not enabled in this build. Books stay on this device."
        #endif
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
}
