import SwiftUI
import AVFAudio
import Combine

@MainActor
final class SpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func toggle(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
            isSpeaking = false
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.86
            synthesizer.speak(utterance)
            isSpeaking = true
        }
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

struct ReaderView: View {
    @ObservedObject var library: BookLibrary
    let bookID: UUID
    @StateObject private var speech = SpeechController()
    @State private var selected: TranslationSpan?
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

    var body: some View {
        Group {
            if let book, let page {
                InteractiveTextView(page: page, selection: selected,
                                    style: ReaderStyle(fontName: font, fontSize: fontSize,
                                                       wordSpacing: wordSpacing, lineSpacing: lineSpacing,
                                                       theme: theme)) { index in
                    selected = page.translations.first { $0.contains(index) }
                }
                .background(Color(uiColor: ReaderStyle(fontName: font, fontSize: fontSize, wordSpacing: wordSpacing, lineSpacing: lineSpacing, theme: theme).background))
                .safeAreaInset(edge: .bottom) {
                    VStack(spacing: 8) {
                        if let selected {
                            HStack(alignment: .firstTextBaseline) {
                                Text(page.words[selected.start...selected.end].map(\.text).joined(separator: " "))
                                    .font(.headline)
                                Spacer()
                                Text(selected.hebrew)
                                    .font(.title3.bold())
                                    .environment(\.layoutDirection, .rightToLeft)
                            }
                            .padding(14)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                        }
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
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(speech.isSpeaking ? "Stop reading" : "Read page aloud",
                               systemImage: speech.isSpeaking ? "stop.fill" : "speaker.wave.2.fill") {
                            speech.toggle(page.text)
                        }
                        Button("Reading appearance", systemImage: "textformat.size") { preferences = true }
                    }
                }
                .sheet(isPresented: $pageChooser) {
                    NavigationStack {
                        Form {
                            TextField("Page number", text: $targetPage)
                                .keyboardType(.numberPad)
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
                .sheet(isPresented: $preferences) {
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
                .onDisappear { speech.stop() }
            } else {
                ContentUnavailableView("Book unavailable", systemImage: "book.closed")
            }
        }
        .navigationTitle(book?.title ?? "Reader")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func changePage(to index: Int) {
        speech.stop()
        selected = nil
        library.setPage(index, in: bookID)
    }
}
