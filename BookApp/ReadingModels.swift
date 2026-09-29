import Foundation

struct WordToken: Codable, Identifiable {
    let id: Int
    let text: String
    /// UTF-16 offsets into the original page text, matching NSAttributedString/UITextView.
    let location: Int
    let length: Int
}

struct TranslationSpan: Codable, Identifiable {
    let start: Int
    let end: Int
    let hebrew: String
    var id: Int { start }
    func contains(_ index: Int) -> Bool { start <= index && index <= end }
}

enum TextFormatKind: String, Codable {
    case title, heading, bold, italic
}

struct TextFormatSpan: Codable {
    /// UTF-16 range within the page text.
    let location: Int
    let length: Int
    let kind: TextFormatKind
}

struct ReadingPage: Codable, Identifiable {
    let id: Int
    let text: String
    let words: [WordToken]
    var translations: [TranslationSpan] = []
    /// Optional so existing PDF books decode without a migration.
    var formatting: [TextFormatSpan]? = nil
}

struct PendingWordTranslation: Codable {
    let id: UUID
    let pageIndex: Int
    let wordIndex: Int
    let modelID: String
    let startedAt: Date
}

struct SavedWordTranslation: Codable {
    let requestID: UUID?
    let pageIndex: Int
    let wordIndex: Int
    let modelID: String
    let rawResponse: String
    let cost: BookTranslationCost?
}

struct WordTranslationFailure: Codable {
    let pageIndex: Int
    let wordIndex: Int
    let message: String
}

enum BookSource: String, Codable {
    case pastedText
}

struct ReadingBook: Codable, Identifiable {
    let id: UUID
    var title: String
    let addedAt: Date
    let fingerprint: String
    var pages: [ReadingPage]
    var modifiedAt: Date? = nil
    var currentPage: Int = 0
    /// Older books without this field were imported from PDF.
    var source: BookSource? = nil
    /// Cost history migrated from books made before translation on tap.
    var historicalCosts: [BookTranslationCost]? = nil
    var historicalRequestCount: Int? = nil
    /// Optional for books written by earlier versions of the app.
    var pendingWordTranslations: [PendingWordTranslation]? = nil
    var savedWordTranslations: [SavedWordTranslation]? = nil
    var wordTranslationFailures: [WordTranslationFailure]? = nil

    var wordCount: Int { pages.reduce(0) { $0 + $1.words.count } }
    var translatedWordCount: Int {
        pages.reduce(0) { total, page in
            total + page.translations.reduce(0) { $0 + $1.end - $1.start + 1 }
        }
    }
}

enum WordTokenizer {
    // Apostrophes stay with contractions; hyphenated compounds remain two tappable words.
    private static let pattern = try! NSRegularExpression(pattern: "[\\p{Latin}]+(?:['’][\\p{Latin}]+)*")

    static func tokenize(_ text: String) -> [WordToken] {
        let nsText = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .enumerated().map { index, match in
                WordToken(id: index, text: nsText.substring(with: match.range),
                          location: match.range.location, length: match.range.length)
            }
    }
}
