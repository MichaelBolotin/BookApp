import SwiftUI
import UIKit

final class BookAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            BackgroundGeminiService.shared.backgroundEventsCompletion = completionHandler
        }
    }
}

@main
struct BookApp: App {
    @UIApplicationDelegateAdaptor(BookAppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
