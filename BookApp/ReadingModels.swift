import Foundation

enum ProcessingState: String, Codable {
    case processing, ready, failed
}

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

struct ReadingPage: Codable, Identifiable {
    let id: Int
    let text: String
    let words: [WordToken]
    var translations: [TranslationSpan] = []
    var completedChunkStarts: [Int] = []
}

struct ReadingBook: Codable, Identifiable {
    let id: UUID
    var title: String
    let addedAt: Date
    let fingerprint: String
    var pages: [ReadingPage]
    var state: ProcessingState
    var errorMessage: String?
    /// Complete successful HTTP response, saved before decoding so relaunch never resends it.
    var rawResponse: String? = nil
    /// Earlier paid responses remain available even after an explicit new request.
    var previousResponses: [String]? = nil
    var currentPage: Int = 0

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
