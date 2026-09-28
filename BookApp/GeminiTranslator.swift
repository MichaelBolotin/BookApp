import Foundation

struct GeminiTranslator {
    let apiKey: String
    let model: AppConfiguration.GeminiModel
    let instructions: String

    static let maximumWords = 6_000

    enum TranslationError: LocalizedError {
        case missingKey, tooLong(Int), invalidResponse(String), invalidCoverage(String), legacyUnaligned(Int, Int), api(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a Gemini API key in Settings before importing a book."
            case .tooLong(let count): "This book has \(count) English words. A single Gemini response can hold at most \(GeminiTranslator.maximumWords) words in this app. No request was sent."
            case .invalidResponse(let detail): "Gemini returned an unusable response: \(detail) The response was saved on this device. A new request requires an explicit retry."
            case .invalidCoverage(let detail): "Gemini did not translate every word correctly: \(detail) The response was saved on this device. A new request requires an explicit retry."
            case .legacyUnaligned(let expected, let received): "The saved response has \(received) translations for \(expected) words, but the earlier format did not include word indexes. Their positions cannot be recovered safely. The paid response remains saved; do not resend it just to inspect this error."
            case .api(let detail): "Gemini request failed: \(detail)"
            }
        }
    }

    func requestTranslation(for pages: [ReadingPage]) async throws -> String {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingKey
        }
        let count = pages.reduce(0) { $0 + $1.words.count }
        guard count <= Self.maximumWords else { throw TranslationError.tooLong(count) }
        var offset = 0
        var sections: [String] = []
        for page in pages {
            let indexed = page.words.enumerated().map { "\(offset + $0.offset): \($0.element.text)" }
                .joined(separator: "\n")
            sections.append("Page \(page.id + 1)\nOriginal text:\n\(page.text)\nIndexed English words:\n\(indexed)")
            offset += page.words.count
        }
        let prompt = """
        \(instructions)

        Return JSON with one object in translations for each indexed English word. Each object
        contains index (its GLOBAL number above), english (copy that exact word), and hebrew
        (its contextual Hebrew translation). Never renumber an index if an item is omitted.
        Include as many valid entries as possible, even if you cannot provide every translation.
        For a meaningful expression of EXACTLY two adjacent English words, also add a phrases entry
        with the first word's global index and the shared Hebrew translation. The translations array
        still contains individual entries for both words. Only use a phrase when the
        two words occur on the same page. No three-word phrases, sentences, or overlapping phrases.
        Keep translations short and contextual. Return no explanations.

        \(sections.joined(separator: "\n\n"))
        """
        let schema: [String: Any] = [
            "type": "object", "properties": [
                // Keep the remote schema small; verify exact length in parse(_:pages:).
                "translations": ["type": "array", "items": [
                    "type": "object", "properties": [
                        "index": ["type": "integer"], "english": ["type": "string"],
                        "hebrew": ["type": "string"]
                    ], "required": ["index", "english", "hebrew"]
                ]],
                "phrases": ["type": "array", "items": [
                    "type": "object", "properties": [
                        "start": ["type": "integer"], "hebrew": ["type": "string"]
                    ], "required": ["start", "hebrew"]
                ]]
            ], "required": ["translations", "phrases"]
        ]
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseFormat": ["text": ["mimeType": "APPLICATION_JSON", "schema": schema]],
                                 "temperature": 0.2, "maxOutputTokens": 65536]
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 600
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        try Task.checkCancellation()
        // One HTTP request only. An uncertain network outcome is never silently retried.
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationError.invalidResponse("No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-UTF-8 response>"
            let message = (try? JSONDecoder().decode(APIError.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw TranslationError.api("HTTP \(http.statusCode): \(message)\n\nModel: \(model.rawValue)\nWords: \(count)\nFull server response:\n\(bodyText)")
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw TranslationError.invalidResponse("HTTP response was not UTF-8.")
        }
        return raw
    }

    struct ParsedBook {
        let pages: [[TranslationSpan]]
        let translatedWords: Int
        let totalWords: Int
    }

    static func parse(_ raw: String, pages: [ReadingPage]) throws -> ParsedBook {
        let count = pages.reduce(0) { $0 + $1.words.count }
        let response: GenerateResponse
        do { response = try JSONDecoder().decode(GenerateResponse.self, from: Data(raw.utf8)) }
        catch { throw TranslationError.invalidResponse("Could not decode the Gemini envelope: \(error.localizedDescription)") }
        guard let candidate = response.candidates?.first else {
            throw TranslationError.invalidResponse("No candidate was returned. \(response.promptFeedback?.blockReason ?? "")")
        }
        guard candidate.finishReason == nil || candidate.finishReason == "STOP" else {
            throw TranslationError.invalidResponse("Generation ended with \(candidate.finishReason ?? "unknown") instead of STOP.")
        }
        guard let payload = candidate.content?.parts?
            .filter({ $0.thought != true }).compactMap(\.text).joined(), !payload.isEmpty else {
            throw TranslationError.invalidResponse("The candidate contained no text.")
        }
        let data = Data(payload.utf8)
        let entries: [TranslationResponse.Entry]
        let phrases: [TranslationResponse.Phrase]
        if let old = try? JSONDecoder().decode(LegacyTranslationResponse.self, from: data) {
            // A shorter unindexed list cannot reveal which words were omitted. Never shift
            // Hebrew meanings onto potentially different English words.
            guard old.translations.count == count else {
                throw TranslationError.legacyUnaligned(count, old.translations.count)
            }
            let originalWords = pages.flatMap(\.words)
            entries = old.translations.enumerated().map { index, hebrew in
                TranslationResponse.Entry(index: index,
                    english: originalWords[index].text, hebrew: hebrew)
            }
            phrases = old.phrases
        } else {
            let translated: TranslationResponse
            do { translated = try JSONDecoder().decode(TranslationResponse.self, from: data) }
            catch { throw TranslationError.invalidResponse("Could not decode translation JSON: \(error.localizedDescription)") }
            entries = translated.translations
            phrases = translated.phrases
        }

        var globalToLocal: [(page: Int, word: Int)] = []
        for (pageIndex, page) in pages.enumerated() {
            globalToLocal += page.words.indices.map { (page: pageIndex, word: $0) }
        }
        var result = pages.map { _ in [Int: TranslationSpan]() }
        for entry in entries {
            guard globalToLocal.indices.contains(entry.index) else { continue }
            let location = globalToLocal[entry.index]
            let expected = pages[location.page].words[location.word].text
            let matches = entry.english.lowercased().replacingOccurrences(of: "’", with: "'")
                == expected.lowercased().replacingOccurrences(of: "’", with: "'")
            let hebrew = entry.hebrew.trimmingCharacters(in: .whitespacesAndNewlines)
            guard matches, !hebrew.isEmpty, result[location.page][location.word] == nil else { continue }
            result[location.page][location.word] =
                TranslationSpan(start: location.word, end: location.word, hebrew: hebrew)
        }
        var occupied = Set<Int>()
        for phrase in phrases {
            guard phrase.start >= 0, phrase.start < count - 1,
                  !occupied.contains(phrase.start), !occupied.contains(phrase.start + 1),
                  globalToLocal[phrase.start].page == globalToLocal[phrase.start + 1].page,
                  !phrase.hebrew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            occupied.insert(phrase.start)
            occupied.insert(phrase.start + 1)
            let location = globalToLocal[phrase.start]
            result[location.page][location.word + 1] = nil
            result[location.page][location.word] =
                TranslationSpan(start: location.word, end: location.word + 1,
                                hebrew: phrase.hebrew.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let ordered = result.map { $0.sorted { $0.key < $1.key }.map { $0.value } }
        let covered = ordered.flatMap { $0 }.reduce(0) { $0 + $1.end - $1.start + 1 }
        guard covered > 0 else {
            throw TranslationError.invalidCoverage("No indexed translations matched the source text.")
        }
        return ParsedBook(pages: ordered, translatedWords: covered, totalWords: count)
    }
}

private struct TranslationResponse: Decodable {
    struct Entry: Decodable {
        let index: Int
        let english: String
        let hebrew: String
    }
    struct Phrase: Decodable { let start: Int; let hebrew: String }
    let translations: [Entry]
    let phrases: [Phrase]
}
private struct LegacyTranslationResponse: Decodable {
    let translations: [String]
    let phrases: [TranslationResponse.Phrase]
}
private struct GenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String?; let thought: Bool? }
            let parts: [Part]?
        }
        let content: Content?
        let finishReason: String?
    }
    struct PromptFeedback: Decodable { let blockReason: String? }
    let candidates: [Candidate]?
    let promptFeedback: PromptFeedback?
}
private struct APIError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
