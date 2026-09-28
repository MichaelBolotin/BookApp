import SwiftUI
import AVFAudio
import Combine

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ word: String) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
        } catch {
            // Speech synthesis can still work with the current audio session.
        }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.86
        currentUtterance = utterance
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        currentUtterance = nil
        isSpeaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance { self.isSpeaking = true }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance {
                self.currentUtterance = nil
                self.isSpeaking = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.currentUtterance === utterance {
                self.currentUtterance = nil
                self.isSpeaking = false
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

struct ReaderView: View {
    @ObservedObject var library: BookLibrary
    let bookID: UUID
    @StateObject private var speech = SpeechController()
    @State private var selectedWordIndex: Int?
    @State private var selectedSpokenWord: String?
    @State private var loadingOpacity = 1.0
    @State private var immersive = false
    @State private var details = false
    @State private var preferences = false
    @State private var pageChooser = false
    @State private var targetPage = "1"
    @AppStorage("readerFont") private var font = "system"
    @AppStorage("readerFontSize") private var fontSize = 20.0
    @AppStorage("readerWordSpacing") private var wordSpacing = 1.0
    @AppStorage("readerLineSpacing") private var lineSpacing = 7.0
    @AppStorage("readerTheme") private var theme = "sepia"

    private var book: ReadingBook? { library.books.first { $0.id == bookID } }
    private var page: ReadingPage? {
        guard let book, book.pages.indices.contains(book.currentPage) else { return nil }
        return book.pages[book.currentPage]
    }
    private var style: ReaderStyle {
        ReaderStyle(fontName: font, fontSize: fontSize, wordSpacing: wordSpacing,
                    lineSpacing: lineSpacing, theme: theme)
    }

    var body: some View {
        Group {
            if let book, let page {
                reader(book: book, page: page)
            } else {
                ContentUnavailableView("Book unavailable", systemImage: "book.closed")
            }
        }
        .navigationTitle(book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func reader(book: ReadingBook, page: ReadingPage) -> some View {
        readingText(page)
            .safeAreaInset(edge: .bottom) { footer(book: book, page: page) }
            .toolbar { readerToolbar }
            .toolbar(immersive ? .hidden : .visible, for: .navigationBar)
            .overlay(alignment: .topTrailing) { revealControlsButton }
            .sheet(isPresented: $details) { BookDetailsView(library: library, bookID: bookID) }
            .sheet(isPresented: $pageChooser) { pageSelection(book: book) }
            .sheet(isPresented: $preferences) { appearanceSettings }
            .onDisappear { speech.stop() }
    }

    private func readingText(_ page: ReadingPage) -> some View {
        let selection = selectedWordIndex.flatMap { index in
            guard page.words.indices.contains(index) else { return nil }
            return page.translations.first { $0.contains(index) } ??
                TranslationSpan(start: index, end: index, hebrew: "")
        }
        return InteractiveTextView(page: page, selection: selection, style: style) { index in
            selectedWordIndex = index
            selectedSpokenWord = page.words[index].text
            library.requestWord(index, on: page.id, in: bookID)
        }
        .background(Color(uiColor: style.background))
    }

    private func footer(book: ReadingBook, page: ReadingPage) -> some View {
        VStack(spacing: 8) {
            selectionCard(page: page)
            if !immersive { pageControls(book: book) }
        }
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func selectionCard(page: ReadingPage) -> some View {
        if let index = selectedWordIndex, page.words.indices.contains(index),
           let selected = page.translations.first(where: { $0.contains(index) }) {
            HStack(alignment: .firstTextBaseline) {
                Text(page.words[selected.start...selected.end].map(\.text).joined(separator: " "))
                    .font(.headline)
                Spacer()
                Text(selected.hebrew)
                    .font(.title3.bold())
                    .environment(\.layoutDirection, .rightToLeft)
                speechButton
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        } else if let index = selectedWordIndex, page.words.indices.contains(index) {
            HStack(spacing: 12) {
                Text(page.words[index].text).font(.headline)
                Spacer(minLength: 12)
                if let failure = book?.wordTranslationFailures?.last(where: {
                    $0.pageIndex == page.id && $0.wordIndex == index
                }) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        Button("Retry translation") {
                            library.requestWord(index, on: page.id, in: bookID, retry: true)
                        }.font(.caption)
                    }
                } else if book?.pendingWordTranslations?.contains(where: {
                    $0.pageIndex == page.id && $0.wordIndex == index
                }) == true {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.gray.opacity(0.35))
                        .frame(width: 100, height: 18)
                        .opacity(loadingOpacity)
                        .accessibilityLabel("Translating word")
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                                loadingOpacity = 0.35
                            }
                        }
                }
                speechButton
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func pageControls(book: ReadingBook) -> some View {
        HStack {
            Button("Previous page", systemImage: "chevron.left") { changePage(to: book.currentPage - 1) }
                .disabled(book.currentPage == 0)
            Spacer()
            Button("Page \(book.currentPage + 1) of \(book.pages.count)") {
                targetPage = String(book.currentPage + 1)
                pageChooser = true
            }
            .monospacedDigit()
            Spacer()
            Button("Next page", systemImage: "chevron.right") { changePage(to: book.currentPage + 1) }
                .disabled(book.currentPage + 1 >= book.pages.count)
        }
        .buttonStyle(.bordered)
    }

    @ToolbarContentBuilder
    private var readerToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button("Book details", systemImage: "info.circle") { details = true }
            Button("Reading appearance", systemImage: "textformat.size") { preferences = true }
            Button("Hide controls", systemImage: "arrow.down.right.and.arrow.up.left") { immersive = true }
        }
    }

    @ViewBuilder
    private var revealControlsButton: some View {
        if immersive {
            Button("Show controls", systemImage: "arrow.up.left.and.arrow.down.right") {
                immersive = false
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .foregroundStyle(style.theme == "dark" ? Color.white : Color.primary)
            .padding(10)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(8)
        }
    }

    private func pageSelection(book: ReadingBook) -> some View {
        NavigationStack {
            Form {
                TextField("Page number", text: $targetPage).keyboardType(.numberPad)
                Text("Enter a page from 1 to \(book.pages.count).")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Go to page")
            .toolbar {
                Button("Go") {
                    if let number = Int(targetPage), (1...book.pages.count).contains(number) {
                        changePage(to: number - 1)
                        pageChooser = false
                    }
                }
                .disabled(Int(targetPage).map { !(1...book.pages.count).contains($0) } ?? true)
            }
        }
        .presentationDetents([.medium])
    }

    private var appearanceSettings: some View {
        NavigationStack {
            Form {
                Picker("Font", selection: $font) {
                    Text("System").tag("system")
                    Text("Serif").tag("serif")
                    Text("Rounded").tag("rounded")
                    Text("Monospaced").tag("mono")
                }
                Slider(value: $fontSize, in: 14...34, step: 1) { Text("Font size") }
                Text("Font size: \(Int(fontSize))")
                Slider(value: $wordSpacing, in: 0...12, step: 1) { Text("Word spacing") }
                Text("Word spacing: \(Int(wordSpacing))")
                Slider(value: $lineSpacing, in: 0...20, step: 1) { Text("Line spacing") }
                Text("Line spacing: \(Int(lineSpacing))")
                Picker("Background", selection: $theme) {
                    Text("Warm paper").tag("sepia")
                    Text("White").tag("white")
                    Text("Dark").tag("dark")
                }
            }
            .navigationTitle("Reading appearance")
            .toolbar { Button("Done") { preferences = false } }
        }
    }

    private func changePage(to index: Int) {
        speech.stop()
        selectedWordIndex = nil
        selectedSpokenWord = nil
        library.setPage(index, in: bookID)
    }

    private var speechButton: some View {
        Button("Read selected word aloud", systemImage: "speaker.wave.2.fill") {
            if let selectedSpokenWord { speech.speak(selectedSpokenWord) }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}
