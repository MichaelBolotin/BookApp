import SwiftUI
import UIKit

struct ReaderStyle {
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
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineSpacing
        let attributed = NSMutableAttributedString(string: page.text, attributes: [
            .font: style.font, .foregroundColor: style.foreground, .paragraphStyle: paragraph
        ])
        let full = NSRange(location: 0, length: (page.text as NSString).length)
        if let spaces = try? NSRegularExpression(pattern: " +") {
            for match in spaces.matches(in: page.text, range: full) {
                attributed.addAttribute(.kern, value: style.wordSpacing, range: match.range)
            }
        }
        if let selection {
            for word in page.words where selection.contains(word.id) {
                attributed.addAttributes([
                    .backgroundColor: style.theme == "dark" ? UIColor.systemIndigo.withAlphaComponent(0.7)
                        : UIColor.systemIndigo.withAlphaComponent(0.25),
                    .foregroundColor: style.theme == "dark" ? UIColor.white : UIColor.black
                ], range: NSRange(location: word.location, length: word.length))
            }
        }
        let pageChanged = context.coordinator.pageID != page.id
        let currentOffset = view.contentOffset
        view.attributedText = attributed
        view.backgroundColor = style.background
        if pageChanged {
            view.setContentOffset(.zero, animated: false)
            context.coordinator.pageID = page.id
        } else {
            view.setContentOffset(currentOffset, animated: false)
        }
    }

    final class Coordinator: NSObject {
        var parent: InteractiveTextView
        weak var view: UITextView?
        var pageID: Int?
        init(_ parent: InteractiveTextView) { self.parent = parent }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let point = recognizer.location(in: view)
            let textPoint = CGPoint(x: point.x - view.textContainerInset.left,
                                    y: point.y - view.textContainerInset.top)
            let manager = view.layoutManager
            let index = manager.characterIndex(for: textPoint, in: view.textContainer,
                                               fractionOfDistanceBetweenInsertionPoints: nil)
            let glyphIndex = manager.glyphIndexForCharacter(at: index)
            let bounds = manager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1),
                                               in: view.textContainer)
            guard bounds.insetBy(dx: -3, dy: -3).contains(textPoint),
                  let word = parent.page.words.first(where: {
                      NSLocationInRange(index, NSRange(location: $0.location, length: $0.length))
                  }) else { return }
            parent.onTapWord(word.id)
        }
    }
}
