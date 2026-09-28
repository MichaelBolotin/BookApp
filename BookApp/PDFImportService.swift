import Foundation
import PDFKit

struct PDFImportService {
    enum ImportError: LocalizedError {
        case invalidPDF, noReadableText
        var errorDescription: String? {
            switch self {
            case .invalidPDF: "The selected file could not be opened as a PDF."
            case .noReadableText: "This PDF contains no selectable English text. Scanned pages need OCR before importing."
            }
        }
    }

    static func extract(from url: URL) throws -> [ReadingPage] {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            throw ImportError.invalidPDF
        }
        var pages: [ReadingPage] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let text = (page.string ?? "").replacingOccurrences(of: "\u{00AD}\n", with: "")
            pages.append(ReadingPage(id: index, text: text, words: WordTokenizer.tokenize(text)))
        }
        guard pages.contains(where: { !$0.words.isEmpty }) else { throw ImportError.noReadableText }
        return pages
    }
}
