import SwiftUI
import UIKit

struct ReaderStyle: Equatable {
    var fontName: String
    var fontSize: CGFloat
    var wordSpacing: CGFloat
    var lineSpacing: CGFloat
    var theme: String

    var font: UIFont {
        switch fontName {
        case "serif": designedFont(.serif)
        case "rounded": designedFont(.rounded)
        case "mono": .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        default: .systemFont(ofSize: fontSize)
        }
    }
    private func designedFont(_ design: UIFontDescriptor.SystemDesign) -> UIFont {
        let base = UIFont.systemFont(ofSize: fontSize)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: fontSize)
    }
    var foreground: UIColor { theme == "dark" ? UIColor(red: 0.91, green: 0.9, blue: 0.86, alpha: 1) : .darkText }
    var background: UIColor {
        switch theme {
        case "dark": UIColor(red: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        case "white": .white
        default: UIColor(red: 0.98, green: 0.96, blue: 0.91, alpha: 1)
        }
    }
}

struct InteractiveTextView: UIViewRepresentable {
    let page: ReadingPage
    let selection: TranslationSpan?
    let style: ReaderStyle
    let onTapWord: (Int) -> Void
    let onDragSelection: (Int, Int) -> Void
    let onTranslateSelection: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = true
        view.textContainerInset = UIEdgeInsets(top: 22, left: 18, bottom: 32, right: 18)
        view.textContainer.lineFragmentPadding = 0
        let recognizer = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(recognizer)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator,
                                                     action: #selector(Coordinator.longPressed(_:)))
        longPress.minimumPressDuration = 0.4
        view.addGestureRecognizer(longPress)
        recognizer.require(toFail: longPress)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let needsNewText = context.coordinator.pageID != page.id
            || context.coordinator.renderedText != page.text
            || context.coordinator.renderedStyle != style
        if needsNewText {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = style.lineSpacing
            let attributed = NSMutableAttributedString(string: page.text, attributes: [
                .font: style.font, .foregroundColor: style.foreground, .paragraphStyle: paragraph
            ])
            let full = NSRange(location: 0, length: (page.text as NSString).length)
            for span in page.formatting ?? [] {
                let range = NSRange(location: span.location, length: span.length)
                guard range.length > 0, NSMaxRange(range) <= full.length else { continue }
                switch span.kind {
                case .title, .heading:
                    let scale: CGFloat = span.kind == .title ? 1.55 : 1.25
                    let weight: UIFont.Weight = span.kind == .title ? .bold : .semibold
                    attributed.addAttribute(.font,
                        value: UIFont.systemFont(ofSize: style.fontSize * scale, weight: weight),
                        range: range)
                    let headingParagraph = paragraph.mutableCopy() as! NSMutableParagraphStyle
                    headingParagraph.paragraphSpacingBefore = style.fontSize * 0.7
                    headingParagraph.paragraphSpacing = style.fontSize * 0.5
                    attributed.addAttribute(.paragraphStyle, value: headingParagraph, range: range)
                case .bold, .italic:
                    let trait: UIFontDescriptor.SymbolicTraits = span.kind == .bold ? .traitBold : .traitItalic
                    let descriptor = style.font.fontDescriptor.withSymbolicTraits(trait)
                    let font = descriptor.map { UIFont(descriptor: $0, size: style.fontSize) }
                        ?? UIFont.systemFont(ofSize: style.fontSize, weight: span.kind == .bold ? .bold : .regular)
                    attributed.addAttribute(.font, value: font, range: range)
                }
            }
            if let spaces = try? NSRegularExpression(pattern: " +") {
                for match in spaces.matches(in: page.text, range: full) {
                    attributed.addAttribute(.kern, value: style.wordSpacing, range: match.range)
                }
            }
            let pageChanged = context.coordinator.pageID != page.id
            let currentOffset = view.contentOffset
            view.attributedText = attributed
            view.backgroundColor = style.background
            context.coordinator.pageID = page.id
            context.coordinator.renderedText = page.text
            context.coordinator.renderedStyle = style
            context.coordinator.renderedSelection = nil
            if pageChanged {
                view.setContentOffset(.zero, animated: false)
            } else {
                view.setContentOffset(currentOffset, animated: false)
            }
        }
        // Editing only the selected ranges keeps UITextView's scroll position intact.
        if context.coordinator.renderedSelection?.start != selection?.start
            || context.coordinator.renderedSelection?.end != selection?.end {
            let storage = view.textStorage
            storage.beginEditing()
            if let previous = context.coordinator.renderedSelection {
                for word in page.words where previous.contains(word.id) {
                    let range = NSRange(location: word.location, length: word.length)
                    storage.removeAttribute(.backgroundColor, range: range)
                    storage.addAttribute(.foregroundColor, value: style.foreground, range: range)
                }
            }
            if let selection {
                for word in page.words where selection.contains(word.id) {
                    storage.addAttributes([
                        .backgroundColor: style.theme == "dark" ? UIColor.systemIndigo.withAlphaComponent(0.7)
                            : UIColor.systemIndigo.withAlphaComponent(0.25),
                        .foregroundColor: style.theme == "dark" ? UIColor.white : UIColor.black
                    ], range: NSRange(location: word.location, length: word.length))
                }
            }
            storage.endEditing()
            context.coordinator.renderedSelection = selection
        }
    }

    final class Coordinator: NSObject {
        var parent: InteractiveTextView
        weak var view: UITextView?
        var pageID: Int?
        var renderedText: String?
        var renderedStyle: ReaderStyle?
        var renderedSelection: TranslationSpan?
        var dragAnchor: Int?
        init(_ parent: InteractiveTextView) { self.parent = parent }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view, let word = word(at: recognizer.location(in: view), exact: true) else { return }
            parent.onTapWord(word)
        }

        @objc func longPressed(_ recognizer: UILongPressGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                dragAnchor = word(at: point, exact: true)
                if let dragAnchor { parent.onDragSelection(dragAnchor, dragAnchor) }
            case .changed:
                if let dragAnchor, let current = word(at: point, exact: false) {
                    parent.onDragSelection(min(dragAnchor, current), max(dragAnchor, current))
                }
            case .ended:
                if let dragAnchor {
                    let current = word(at: point, exact: false) ?? dragAnchor
                    parent.onTranslateSelection(min(dragAnchor, current), max(dragAnchor, current))
                }
                dragAnchor = nil
            default:
                dragAnchor = nil
            }
        }

        private func word(at point: CGPoint, exact: Bool) -> Int? {
            guard let view, !parent.page.words.isEmpty else { return nil }
            let textPoint = CGPoint(x: point.x - view.textContainerInset.left,
                                    y: point.y - view.textContainerInset.top)
            let manager = view.layoutManager
            let index = manager.characterIndex(for: textPoint, in: view.textContainer,
                                               fractionOfDistanceBetweenInsertionPoints: nil)
            let glyphIndex = manager.glyphIndexForCharacter(at: index)
            let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                               in: view.textContainer)
            if exact && !bounds.insetBy(dx: -3, dy: -3).contains(textPoint) { return nil }
            if let word = parent.page.words.first(where: {
                NSLocationInRange(index, NSRange(location: $0.location, length: $0.length))
            }) { return word.id }
            guard !exact else { return nil }
            return parent.page.words.min(by: {
                abs($0.location - index) < abs($1.location - index)
            })?.id
        }
    }
}
