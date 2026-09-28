import Foundation

/// Standard paid-tier estimate, not a bill. Free-tier usage or discounts may cost less.
struct BookTranslationCost: Codable {
    let modelID: String
    let inputTokens: Int
    let outputTokens: Int
    let thoughtTokens: Int
    let inputUSDPerMillion: Double
    let outputUSDPerMillion: Double
    let estimatedUSD: Double
    let calculatedAt: Date

    static func estimate(rawResponse: String, requestedModel: String?, at date: Date = Date()) -> Self? {
        struct UsageEnvelope: Decodable {
            struct Usage: Decodable {
                let promptTokenCount: Int?
                let candidatesTokenCount: Int?
                let thoughtsTokenCount: Int?
            }
            let modelVersion: String?
            let usageMetadata: Usage?
        }
        guard let envelope = try? JSONDecoder().decode(UsageEnvelope.self, from: Data(rawResponse.utf8)),
              let usage = envelope.usageMetadata,
              let input = usage.promptTokenCount,
              let output = usage.candidatesTokenCount else { return nil }
        let model = requestedModel ?? envelope.modelVersion ?? ""
        let rates: (Double, Double)
        switch model {
        case "gemini-3.5-flash-lite": rates = (0.30, 2.50)
        case "gemini-3.1-flash-lite": rates = (0.25, 1.50)
        case "gemini-3.8-flash":
            let change = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2027, month: 1, day: 1))!
            rates = date < change ? (0.75, 3.75) : (1.50, 7.50)
        default: return nil
        }
        let thought = usage.thoughtsTokenCount ?? 0
        let amount = (Double(input) * rates.0 + Double(output + thought) * rates.1) / 1_000_000
        return Self(modelID: model, inputTokens: input, outputTokens: output, thoughtTokens: thought,
                    inputUSDPerMillion: rates.0, outputUSDPerMillion: rates.1,
                    estimatedUSD: amount, calculatedAt: date)
    }
}
