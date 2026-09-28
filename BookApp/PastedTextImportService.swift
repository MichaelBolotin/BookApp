import Foundation
import UIKit
import UniformTypeIdentifiers

/// Turns a clipboard document into readable pages while retaining structural formatting.
enum PastedTextImportService {
    enum ImportError: LocalizedError {
        case emptyClipboard
        var errorDescription: String? {
            "Copy some readable text before tapping Paste."
        }
    }

    static func extract(from pasteboard: UIPasteboard = .general) throws -> (title: String, pages: [ReadingPage]) {
        if let rtf = pasteboard.data(forPasteboardType: UTType.rtf.identifier),
           let attributed = try? NSAttributedString(data: rtf,
               options: [.documentType: NSAttributedString.DocumentType.rtf],
               documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return makeBook(from: attributed)
        }
        if let html = pasteboard.data(forPasteboardType: UTType.html.identifier),
           let attributed = try? NSAttributedString(data: html,
               options: [.documentType: NSAttributedString.DocumentType.html],
               documentAttributes: nil),
           !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return makeBook(from: attributed)
        }
        guard let plain = pasteboard.string,
              !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.emptyClipboard
        }
        return makeBook(fromMarkdown: plain)
    }

    private static func makeBook(from attributed: NSAttributedString) -> (title: String, pages: [ReadingPage]) {
        let text = attributed.string
        let range = NSRange(location: 0, length: attributed.length)
        var bodyFontSize = UIFont.systemFontSize
        var longestRun = 0
        attributed.enumerateAttribute(.font, in: range) { value, run, _ in
            if let font = value as? UIFont, run.length > longestRun {
                bodyFontSize = font.pointSize
                longestRun = run.length
            }
        }
        var formatting: [TextFormatSpan] = []
        attributed.enumerateAttribute(.font, in: range) { value, run, _ in
            guard let font = value as? UIFont, run.length > 0 else { return }
            let traits = font.fontDescriptor.symbolicTraits
            if font.pointSize >= max(18, bodyFontSize * 1.25) {
                formatting.append(TextFormatSpan(location: run.location, length: run.length,
                                                  kind: font.pointSize >= bodyFontSize * 1.65 ? .title : .heading))
            } else {
                if traits.contains(.traitBold) {
                    formatting.append(TextFormatSpan(location: run.location, length: run.length, kind: .bold))
                }
                if traits.contains(.traitItalic) {
                    formatting.append(TextFormatSpan(location: run.location, length: run.length, kind: .italic))
                }
            }
        }
        return assemble(text: text, formatting: formatting)
    }

    private static func makeBook(fromMarkdown source: String) -> (title: String, pages: [ReadingPage]) {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let heading = try! NSRegularExpression(pattern: "^ {0,3}(#{1,6}) +(.+?)(?: +#+)? *$")
        let emphasis = try! NSRegularExpression(
            pattern: "\\*\\*([^*\\n]+)\\*\\*|__([^_\\n]+)__|(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)|(?<!_)_([^_\\n]+)_(?!_)")
        var text = ""
        var offset = 0
        var formatting: [TextFormatSpan] = []
        for (index, part) in normalized.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { text.append("\n"); offset += 1 }
            var line = String(part)
            var kind: TextFormatKind?
            let nsLine = line as NSString
            if let match = heading.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) {
                let depth = nsLine.substring(with: match.range(at: 1)).count
                line = nsLine.substring(with: match.range(at: 2))
                kind = depth == 1 ? .title : .heading
            } else if line.count < 120, line.hasPrefix("**"), line.hasSuffix("**"), line.count > 4 {
                line = String(line.dropFirst(2).dropLast(2))
                kind = .heading
            }
            let sourceLine = line as NSString
            let matches = emphasis.matches(in: line, range: NSRange(location: 0, length: sourceLine.length))
            var cursor = 0
            let lineStart = offset
            for match in matches {
                let before = sourceLine.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                text += before
                offset += (before as NSString).length
                let innerIndex = (1...4).first { match.range(at: $0).location != NSNotFound }!
                let inner = sourceLine.substring(with: match.range(at: innerIndex))
                let length = (inner as NSString).length
                if kind == nil {
                    formatting.append(TextFormatSpan(location: offset, length: length,
                        kind: innerIndex <= 2 ? .bold : .italic))
                }
                text += inner
                offset += length
                cursor = NSMaxRange(match.range)
            }
            let tail = sourceLine.substring(from: cursor)
            text += tail
            offset += (tail as NSString).length
            if let kind, offset > lineStart {
                formatting.append(TextFormatSpan(location: lineStart, length: offset - lineStart, kind: kind))
            }
        }
        return assemble(text: text, formatting: formatting)
    }

    private static func assemble(text: String, formatting: [TextFormatSpan]) -> (title: String, pages: [ReadingPage]) {
        let nsText = text as NSString
        let titleSpan = formatting.first { $0.kind == .title || $0.kind == .heading }
        let firstLine = text.split(whereSeparator: \.isNewline).first { !String($0).trimmingCharacters(in: .whitespaces).isEmpty }
        let proposed = titleSpan.map { nsText.substring(with: NSRange(location: $0.location, length: $0.length)) }
            ?? firstLine.map(String.init) ?? "Pasted text"
        let title = String(proposed.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        var pages: [ReadingPage] = []
        var start = 0
        while start < nsText.length {
            var end = min(start + 6000, nsText.length)
            if end < nsText.length {
                let backward = nsText.range(of: "\n", options: .backwards,
                    range: NSRange(location: start, length: end - start))
                if backward.location != NSNotFound, backward.location > start + 2000 {
                    end = NSMaxRange(backward)
                } else {
                    end = nsText.rangeOfComposedCharacterSequence(at: end).location
                }
            }
            let pageText = nsText.substring(with: NSRange(location: start, length: end - start))
            let pageFormatting = formatting.compactMap { span -> TextFormatSpan? in
                let lower = max(start, span.location)
                let upper = min(end, span.location + span.length)
                guard upper > lower else { return nil }
                return TextFormatSpan(location: lower - start, length: upper - lower, kind: span.kind)
            }
            pages.append(ReadingPage(id: pages.count, text: pageText,
                                     words: WordTokenizer.tokenize(pageText), formatting: pageFormatting))
            start = end
        }
        return (title.isEmpty ? "Pasted text" : title, pages)
    }
}
