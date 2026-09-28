# BookApp

A personal iPhone/iPad reading aid for English PDFs. Import a text-based PDF, wait for Gemini to prepare contextual Hebrew translations, then tap a word to see its saved translation. A short two-word expression shares one highlighted translation. Reading appearance and system speech are available offline after processing.

## Setup

1. Open `BookApp.xcodeproj` in Xcode 26, select your Apple development team, and run on iOS 26 or later.
2. Get a Gemini API key from Google AI Studio. Open Settings in the app and enter the key. It is saved in the device Keychain.
3. Optionally choose a model and edit the translation instructions in Settings. The defaults and model list live in `BookApp/AppConfiguration.swift`.
4. Import a PDF with selectable English text. Scanned image PDFs are not yet supported.

The app copies the source PDF and stores extracted pages, word positions, translations, checkpoints, and reading position in Application Support on this device. The original PDF is retained locally; only extracted text batches (80 words and nearby context) are sent to Google's Gemini API. The same file's SHA-256 prevents accidental duplicate import. A failed or interrupted preparation resumes from saved batches; swipe a book to delete local data. A successful book is never sent again during reading. The iOS speech synthesizer reads the current page without a paid speech API.

The REST integration uses `generateContent` with JSON structured output. Every batch is checked for complete, ordered coverage with one-word entries or adjacent two-word expressions before it is saved. Batch boundaries can separate an expression. Large books require many requests and incur Gemini API charges. Processing currently runs while the app is active; iOS may suspend it in the background, and the app continues at the next launch. A translation may still be imperfect, and a request that succeeds remotely just before interruption might be retried if its checkpoint was not saved.

For personal use the key stays on this device. Do not commit a key in source control. A distributed app needs a backend to protect the key. The repository does not include a real key.
