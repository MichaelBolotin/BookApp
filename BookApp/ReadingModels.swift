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
    var currentPage: Int = 0

    var totalChunks: Int { pages.reduce(0) { $0 + $1.words.count.chunksNeeded } }
    var completedChunks: Int { pages.reduce(0) { $0 + $1.completedChunkStarts.count } }
    var progress: Double { totalChunks == 0 ? 1 : Double(completedChunks) / Double(totalChunks) }
}

enum TranslationBatch {
    static let wordLimit = 80
}

private extension Int {
    var chunksNeeded: Int { (self + TranslationBatch.wordLimit - 1) / TranslationBatch.wordLimit }
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
