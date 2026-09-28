import Foundation

struct GeminiTranslator {
    let apiKey: String
    let model: AppConfiguration.GeminiModel
    let instructions: String

    static let maximumWords = 6_000

    enum TranslationError: LocalizedError {
        case missingKey, tooLong(Int), invalidResponse(String), invalidCoverage(String), api(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a Gemini API key in Settings before importing a book."
            case .tooLong(let count): "This book has \(count) English words. A single Gemini response can hold at most \(GeminiTranslator.maximumWords) words in this app. No request was sent."
            case .invalidResponse(let detail): "Gemini returned an unusable response: \(detail) The response was saved on this device. A new request requires an explicit retry."
            case .invalidCoverage(let detail): "Gemini did not translate every word correctly: \(detail) The response was saved on this device. A new request requires an explicit retry."
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

        Return JSON with exactly \(count) Hebrew translations in the translations array. Array position 0
        translates indexed word 0, and so on through \(count - 1). Never skip, merge, or reorder an item.
        For a meaningful expression of EXACTLY two adjacent English words, also add a phrases entry
        with the first word's global index and the shared Hebrew translation. The translations array
        still contains individual Hebrew translations for both words. Only use a phrase when the
        two words occur on the same page. No three-word phrases, sentences, or overlapping phrases.
        Keep translations short and contextual. Return no explanations.

        \(sections.joined(separator: "\n\n"))
        """
        let schema: [String: Any] = [
            "type": "object", "properties": [
                "translations": ["type": "array", "minItems": count, "maxItems": count,
                                 "items": ["type": "string"]],
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
            let detail = (try? JSONDecoder().decode(APIError.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw TranslationError.api("HTTP \(http.statusCode): \(detail)")
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            throw TranslationError.invalidResponse("HTTP response was not UTF-8.")
        }
        return raw
    }

    static func parse(_ raw: String, pages: [ReadingPage]) throws -> [[TranslationSpan]] {
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
        let translated: TranslationResponse
        do { translated = try JSONDecoder().decode(TranslationResponse.self, from: Data(payload.utf8)) }
        catch { throw TranslationError.invalidResponse("Could not decode translation JSON: \(error.localizedDescription)") }
        guard translated.translations.count == count else {
            throw TranslationError.invalidCoverage("Expected \(count) words, received \(translated.translations.count).")
        }
        let values = translated.translations.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let index = values.firstIndex(where: \.isEmpty) {
            throw TranslationError.invalidCoverage("Translation at index \(index) was empty.")
        }
        var result: [[TranslationSpan]] = []
        var offset = 0
        for page in pages {
            result.append(page.words.indices.map { local in
                TranslationSpan(start: local, end: local, hebrew: values[offset + local])
            })
            offset += page.words.count
        }
        var globalToLocal: [(page: Int, word: Int)] = []
        for (pageIndex, page) in pages.enumerated() {
            globalToLocal += page.words.indices.map { (page: pageIndex, word: $0) }
        }
        var occupied = Set<Int>()
        // Replace from highest index so removing a word cannot shift a later phrase.
        for phrase in translated.phrases.sorted(by: { $0.start > $1.start }) {
            guard phrase.start >= 0, phrase.start < count - 1,
                  !occupied.contains(phrase.start), !occupied.contains(phrase.start + 1),
                  globalToLocal[phrase.start].page == globalToLocal[phrase.start + 1].page,
                  !phrase.hebrew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationError.invalidCoverage("Invalid or overlapping two-word phrase at index \(phrase.start).")
            }
            occupied.insert(phrase.start)
            occupied.insert(phrase.start + 1)
            let location = globalToLocal[phrase.start]
            result[location.page][location.word] = TranslationSpan(start: location.word, end: location.word + 1,
                hebrew: phrase.hebrew.trimmingCharacters(in: .whitespacesAndNewlines))
            result[location.page].remove(at: location.word + 1)
        }
        return result
    }
}

private struct TranslationResponse: Decodable {
    struct Phrase: Decodable { let start: Int; let hebrew: String }
    let translations: [String]
    let phrases: [Phrase]
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
