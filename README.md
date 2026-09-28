# BookApp

A personal iPhone/iPad reading aid for English PDFs. Import a text-based PDF and read immediately. Tapping a word requests its contextual Hebrew meaning from Gemini; tapping it again uses the saved result. Reading appearance and system speech are available without an API request.

## Setup

1. Open `BookApp.xcodeproj` in Xcode 26, select your Apple development team, and run on iOS 26 or later. The default target does not request an iCloud entitlement, so it can also be signed by an Xcode Personal Team.
2. Get a Gemini API key from Google AI Studio. Open Settings in the app and enter the key. It is saved in the device Keychain.
3. Optionally choose a model in Settings. The model list lives in `BookApp/AppConfiguration.swift`.
4. Import a PDF with selectable English text. Scanned image PDFs are not yet supported.

### Enable iCloud sync

CloudKit requires a team with the iCloud capability (Apple Developer Program membership). A free Xcode Personal Team cannot sign the app with this entitlement. With an eligible team, set a stable, unique bundle identifier **before** creating the iCloud container; changing the identifier later creates a different installed app and does not automatically migrate its locally stored books. In Signing & Capabilities, add **iCloud → CloudKit** and select the matching `iCloud.<bundle identifier>` container. Xcode can create the entitlement or you can point `CODE_SIGN_ENTITLEMENTS` for both target configurations to the provided `BookApp/BookApp.entitlements`. The selected container must exist for your team. Then add `CLOUDKIT_ENABLED` to **Swift Active Compilation Conditions** for both target configurations. **Add this condition only after the entitlement and container are configured:** creating `CKContainer.default()` without them terminates the app. Deploy the CloudKit schema to Production before distribution, then sign in with the same Apple Account on each device. Until then, books remain local and Settings reports that iCloud sync is disabled.

The app copies the source PDF and stores extracted pages, word positions, translations, raw Gemini responses, and reading position in Application Support on this device. Books and PDFs sync to the private iCloud database when CloudKit is available. Settings shows the sync status and offers **Sync now**. Import sends nothing to Gemini. A tap sends just the selected word and up to ten words on either side; the response is saved by word position. A failed request shows a retry button, and no repeated tap silently resends a paid request. The same file's SHA-256 prevents accidental duplicate import. Swipe a book to delete it after confirmation. Select a word, then tap its speaker button for free iOS speech of that word. **Hide controls** clears the reader navigation and page controls while keeping the translation card accessible.

Word requests use `generateContent` with a one-field JSON response. The exact page and word index are stored locally with each request. A response and its token usage are saved before validation; a saved response can be parsed after relaunch without another request. File-backed iOS background uploads allow transfers to finish after the app is suspended. iOS controls scheduling, and force quitting can cancel background work. If a transfer ends without a saved response, its remote outcome is unknown and only an explicit retry sends another request. Translations may still be imperfect.

Each book’s **Book details** screen (long press its library row or tap info in the reader) sums token usage and estimated paid-tier cost in USD across its requests. Existing books retain saved translations and previously recorded cost estimates. Rates are stored with each new result. This is an estimate, not an actual invoice; free-tier usage, discounts, taxes, and price changes can change the amount paid. Models without usage or a known rate are excluded from the estimate. Thinking tokens use the output rate.

For a failed word request, select a model in Settings if needed and tap **Retry translation** under the selected word to send one new request. Changing the model alone does not send data.

For personal use the key stays on this device. Do not commit a key in source control. A distributed app needs a backend to protect the key. The repository does not include a real key.
