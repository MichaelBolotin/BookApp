# BookApp

A personal iPhone/iPad reading aid for English PDFs. Import a text-based PDF, wait for Gemini to prepare contextual Hebrew translations, then tap a word to see its saved translation. A short two-word expression shares one highlighted translation. Reading appearance and system speech are available offline after processing.

## Setup

1. Open `BookApp.xcodeproj` in Xcode 26, select your Apple development team, and run on iOS 26 or later.
2. Get a Gemini API key from Google AI Studio. Open Settings in the app and enter the key. It is saved in the device Keychain.
3. Optionally choose a model and edit the translation instructions in Settings. The defaults and model list live in `BookApp/AppConfiguration.swift`.
4. Import a PDF with selectable English text. Scanned image PDFs are not yet supported.

The app copies the source PDF and stores extracted pages, word positions, translations, the raw Gemini response, and reading position in Application Support on this device. The original PDF is retained locally; the extracted text of the entire book is sent in one Gemini request. The same file's SHA-256 prevents accidental duplicate import. Tap a failed book to read the full error; only the explicit retry button sends a new request. Swipe a book to delete local data. A successful book is never sent again during reading. The iOS speech synthesizer reads the current page without a paid speech API.

The REST integration uses `generateContent` with JSON structured output. It requests exactly one translation per indexed word, plus optional two-word phrases. The response is saved before validation and all words are checked before the book becomes readable. To fit a single model response, imports above 6,000 English words stop before an API call with a clear error. Processing runs while the app is active; iOS may suspend it in the background. A saved response is parsed again at the next launch without another request. If a request was interrupted before its response was saved, its outcome is unknown and only an explicit retry sends the book again. Translations may still be imperfect.

For personal use the key stays on this device. Do not commit a key in source control. A distributed app needs a backend to protect the key. The repository does not include a real key.
