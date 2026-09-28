import Foundation

/// Personal configuration. Enter the key in the app Settings (device Keychain).
/// The optional fallback below is for local development; never commit a real key.
enum AppConfiguration {
    static let fallbackAPIKey = "" // Optional local development key. Never commit a real key.

    enum GeminiModel: String, CaseIterable, Identifiable {
        case flashLite = "gemini-3.5-flash-lite"
        case flash = "gemini-3.8-flash"
        case flashLite31 = "gemini-3.1-flash-lite"

        var id: String { rawValue }
        var title: String {
            switch self {
            case .flashLite: "Gemini 3.5 Flash-Lite"
            case .flash: "Gemini 3.8 Flash"
            case .flashLite31: "Gemini 3.1 Flash-Lite"
            }
        }
    }

    static let defaultModel: GeminiModel = .flashLite

    /// Editable in Settings. The output contract and validation are enforced in code.
    static let defaultInstructions = """
    You are preparing an English reading aid for a Hebrew-speaking learner.
    Translate EVERY indexed English word in its specific narrative context into short, natural Hebrew.
    A translation should normally be one Hebrew word. If two adjacent English words form an idiom,
    phrasal verb, proper name, or fixed expression whose meaning would be misleading separately,
    also provide ONE shared Hebrew translation for exactly those two words in phrases.
    Never group three or more words, a full sentence, or unrelated adjacent words.
    Preserve the indexed word order: translations must contain one entry for EVERY indexed word,
    including both words of each phrase. Phrase starts are zero-based GLOBAL indexes.
    Hebrew values must be nonempty, concise, and contain no explanations, punctuation-only values,
    romanization, or English. Resolve pronouns and inflection from context when possible.
    """
}
