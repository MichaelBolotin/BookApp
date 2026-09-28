import Foundation

nonisolated struct SavedGeminiTransfer: Codable {
    let status: Int?
    let body: Data
    let error: String?
}

/// One file-backed URLSession upload per book. iOS owns the transfer after the app is suspended.
@MainActor
final class BackgroundGeminiService: NSObject, URLSessionDataDelegate {
    static let shared = BackgroundGeminiService()

    var onResult: ((UUID) -> Void)?
    var backgroundEventsCompletion: (() -> Void)?
    nonisolated private let directory: URL
    private var session: URLSession!
    nonisolated(unsafe) private var buffers: [Int: Data] = [:]
    nonisolated private let bufferLock = NSLock()

    private override init() {
        directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeminiTransfers", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identifier = (Bundle.main.bundleIdentifier ?? "BookApp") + ".gemini-upload"
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func enqueue(bookID: UUID, request: URLRequest, body: Data) throws {
        let file = directory.appendingPathComponent(bookID.uuidString + ".request")
        try body.write(to: file, options: .atomic)
        let task = session.uploadTask(with: request, fromFile: file)
        task.taskDescription = bookID.uuidString
        task.resume()
    }

    func activeBookIDs() async -> Set<UUID> {
        await withCheckedContinuation { continuation in
            session.getAllTasks { tasks in
                continuation.resume(returning: Set(tasks.compactMap { $0.taskDescription.flatMap(UUID.init(uuidString:)) }))
            }
        }
    }

    func cancel(_ id: UUID) {
        session.getAllTasks { tasks in
            for task in tasks where task.taskDescription == id.uuidString { task.cancel() }
        }
    }

    func result(_ id: UUID) -> SavedGeminiTransfer? {
        let file = directory.appendingPathComponent(id.uuidString + ".result")
        guard let data = try? Data(contentsOf: file),
              let result = try? JSONDecoder().decode(SavedGeminiTransfer.self, from: data) else { return nil }
        return result
    }

    func removeResult(_ id: UUID) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".result"))
    }

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                                didReceive data: Data) {
        bufferLock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        bufferLock.unlock()
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        bufferLock.lock()
        let body = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        bufferLock.unlock()
        guard let identifier = task.taskDescription, let id = UUID(uuidString: identifier) else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let failure = error?.localizedDescription
        let result = SavedGeminiTransfer(status: status, body: body, error: failure)
        let file = directory.appendingPathComponent(id.uuidString + ".result")
        do {
            // Persist before returning from the delegate callback. iOS can suspend the app
            // immediately after the background-session events completion handler runs.
            try JSONEncoder().encode(result).write(to: file, options: .atomic)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(id.uuidString + ".request"))
            Task { @MainActor in onResult?(id) }
        } catch {
            // Reconciliation reports the missing result without sending another request.
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            backgroundEventsCompletion?()
            backgroundEventsCompletion = nil
        }
    }
}
