import Foundation

/// Personal configuration. Enter the key in the app Settings (device Keychain).
/// The optional fallback below is for local development; never commit a real key.
enum AppConfiguration {
    static let fallbackAPIKey = "" // Optional local development key. Never commit a real key.

    /// Enable CLOUDKIT_ENABLED only in a build signed with a matching entitlement.
    /// CKContainer.default() aborts at runtime if that entitlement is missing.
    #if CLOUDKIT_ENABLED
    static let cloudKitEnabled = true
    #else
    static let cloudKitEnabled = false
    #endif

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

}
