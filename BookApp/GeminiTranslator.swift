import Foundation

struct GeminiTranslator {
    let apiKey: String
    let model: AppConfiguration.GeminiModel
    let instructions: String

    enum TranslationError: LocalizedError {
        case missingKey, invalidResponse, invalidCoverage, api(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a Gemini API key in Settings before importing a book."
            case .invalidResponse: "Gemini did not return usable JSON. Tap Resume to retry this batch."
            case .invalidCoverage: "Gemini omitted or combined words incorrectly. Tap Resume to retry this batch."
            case .api(let detail): "Gemini request failed: \(detail)"
            }
        }
    }

    func translate(words: [WordToken], context: String) async throws -> [TranslationSpan] {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.missingKey
        }
        guard !words.isEmpty else { return [] }
        let indexed = words.enumerated().map { "\($0.offset): \($0.element.text)" }.joined(separator: "\n")
        let prompt = """
        \(instructions)

        Narrative context (for meaning only; never add output items for context):
        \(context)

        Translate these indexed words, in order:
        \(indexed)
        """
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["items": [
                "type": "array",
                "items": ["type": "object", "properties": [
                    "start": ["type": "integer"], "end": ["type": "integer"],
                    "hebrew": ["type": "string"]],
                    "required": ["start", "end", "hebrew"]]
            ]], "required": ["items"]
        ]
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseFormat": ["text": ["mimeType": "application/json", "schema": schema]],
                                 "temperature": 0.2, "maxOutputTokens": 8192]
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 120
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var data = Data()
        var http: HTTPURLResponse?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let (received, response) = try await URLSession.shared.data(for: request)
            data = received
            http = response as? HTTPURLResponse
            guard let status = http?.statusCode else { throw TranslationError.invalidResponse }
            if status == 429 || (500...599).contains(status) {
                if attempt < 2 {
                    try await Task.sleep(for: .seconds(Double(2 << attempt)))
                    continue
                }
            }
            break
        }
        guard let http else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIError.self, from: data).error.message)
                ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw TranslationError.api("HTTP \(http.statusCode): \(detail)")
        }
        guard let result = try? JSONDecoder().decode(GenerateResponse.self, from: data),
              let payload = result.candidates?.first?.content?.parts?.compactMap(\.text).joined(),
              let translated = try? JSONDecoder().decode(TranslationResponse.self, from: Data(payload.utf8)) else {
            throw TranslationError.invalidResponse
        }
        var next = 0
        var spans: [TranslationSpan] = []
        for item in translated.items {
            guard item.start == next, item.end >= item.start, item.end <= item.start + 1,
                  item.end < words.count,
                  !item.hebrew.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationError.invalidCoverage
            }
            spans.append(TranslationSpan(start: item.start, end: item.end,
                                         hebrew: item.hebrew.trimmingCharacters(in: .whitespacesAndNewlines)))
            next = item.end + 1
        }
        guard next == words.count else { throw TranslationError.invalidCoverage }
        return spans
    }
}

private struct TranslationResponse: Decodable {
    struct Item: Decodable { let start: Int; let end: Int; let hebrew: String }
    let items: [Item]
}
private struct GenerateResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable { let text: String? }
            let parts: [Part]?
        }
        let content: Content?
    }
    let candidates: [Candidate]?
}
private struct APIError: Decodable {
    struct Detail: Decodable { let message: String }
    let error: Detail
}
