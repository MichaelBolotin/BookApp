import Foundation

/// Sends one selected word with a small context window.
struct OnDemandWordTranslator {
    let apiKey: String
    let model: AppConfiguration.GeminiModel

    func makeRequest(pages: [ReadingPage], pageIndex: Int, wordIndex: Int) throws -> (URLRequest, Data) {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingKey
        }
        guard pages.indices.contains(pageIndex), pages[pageIndex].words.indices.contains(wordIndex) else {
            throw Error.invalidWord
        }
        // The window crosses page boundaries, so words at a page edge still get ten neighbors.
        let words = pages.flatMap(\.words)
        let globalIndex = pages[..<pageIndex].reduce(0) { $0 + $1.words.count } + wordIndex
        let lower = max(0, globalIndex - 10)
        let upper = min(words.count - 1, globalIndex + 10)
        let context = (lower...upper).map { index in
            index == globalIndex ? "[TARGET: \(words[index].text)]" : words[index].text
        }.joined(separator: " ")
        let prompt = """
        Translate only the English word marked TARGET into short, natural Hebrew as used in this story.
        The other words are context only; do not translate them or return a sentence.
        Return one concise Hebrew meaning in the JSON field hebrew. Do not add explanations.
        Target word: \(words[globalIndex].text)
        Context (up to ten words before and ten words after): \(context)
        """
        let schema: [String: Any] = [
            "type": "object", "properties": ["hebrew": ["type": "string"]], "required": ["hebrew"]
        ]
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "generationConfig": ["responseFormat": ["text": ["mimeType": "APPLICATION_JSON", "schema": schema]],
                                 "temperature": 0.2, "maxOutputTokens": 128]
        ]
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model.rawValue):generateContent")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 600
        return (request, try JSONSerialization.data(withJSONObject: body))
    }

    static func parse(_ raw: String) throws -> String {
        struct Envelope: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable { let text: String?; let thought: Bool? }
                    let parts: [Part]?
                }
                let content: Content?
                let finishReason: String?
            }
            let candidates: [Candidate]?
        }
        struct Meaning: Decodable { let hebrew: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(raw.utf8)),
              let candidate = envelope.candidates?.first,
              candidate.finishReason == nil || candidate.finishReason == "STOP",
              let parts = candidate.content?.parts else { throw Error.invalidResponse }
        let payload = parts.filter { $0.thought != true }.compactMap(\.text).joined()
        guard let meaning = try? JSONDecoder().decode(Meaning.self, from: Data(payload.utf8)) else {
            throw Error.invalidResponse
        }
        let hebrew = meaning.hebrew.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !hebrew.isEmpty else { throw Error.invalidResponse }
        return hebrew
    }

    static func responseError(status: Int, data: Data, modelID: String) -> Error {
        struct APIError: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }
        let message = (try? JSONDecoder().decode(APIError.self, from: data).error.message)
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .api("HTTP \(status): \(message) (model: \(modelID))")
    }

    enum Error: LocalizedError {
        case missingKey, invalidWord, invalidResponse, api(String)
        var errorDescription: String? {
            switch self {
            case .missingKey: "Add a Gemini API key in Settings before translating a word."
            case .invalidWord: "This word is no longer available in the book."
            case .invalidResponse: "Gemini returned no usable translation. The paid response was saved; retry only if you want to send another request."
            case .api(let message): "Gemini request failed: \(message)"
            }
        }
    }
}
