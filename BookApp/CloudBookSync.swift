import CloudKit
import Foundation

/// Mirrors local book snapshots and PDFs to the user's private CloudKit database.
@MainActor
final class CloudBookSync {
    struct RemoteBook {
        let id: UUID
        let modifiedAt: Date
        let deleted: Bool
        let snapshot: Data?
        let pdf: Data?
    }

    private let database = CKContainer.default().privateCloudDatabase
    private let recordType = "BookFile"

    func fetchAll() async throws -> [RemoteBook] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        var page = try await database.records(matching: query, resultsLimit: 100)
        var records: [RemoteBook] = []
        while true {
            for (_, result) in page.matchResults {
                let record = try result.get()
                guard let id = UUID(uuidString: record.recordID.recordName) else { continue }
                let snapshotURL = (record["snapshot"] as? CKAsset)?.fileURL
                let pdfURL = (record["pdf"] as? CKAsset)?.fileURL
                records.append(RemoteBook(
                    id: id, modifiedAt: (record["modifiedAt"] as? Date) ?? .distantPast,
                    deleted: (record["deleted"] as? NSNumber)?.boolValue ?? false,
                    snapshot: snapshotURL.flatMap { try? Data(contentsOf: $0) },
                    pdf: pdfURL.flatMap { try? Data(contentsOf: $0) }))
            }
            guard let cursor = page.queryCursor else { break }
            page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 100)
        }
        return records
    }

    func upload(_ book: ReadingBook, snapshotURL: URL, pdfURL: URL?) async throws {
        let id = CKRecord.ID(recordName: book.id.uuidString)
        let record = try await existingRecord(for: id) ?? CKRecord(recordType: recordType, recordID: id)
        let remoteDate = (record["modifiedAt"] as? Date) ?? .distantPast
        guard remoteDate <= (book.modifiedAt ?? book.addedAt) else { return }
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: snapshotURL, to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }
        record["snapshot"] = CKAsset(fileURL: staged)
        if record["pdf"] == nil, let pdfURL { record["pdf"] = CKAsset(fileURL: pdfURL) }
        record["modifiedAt"] = (book.modifiedAt ?? book.addedAt) as NSDate
        record["deleted"] = NSNumber(value: false)
        _ = try await database.save(record)
    }

    func delete(_ id: UUID, at date: Date) async throws {
        let recordID = CKRecord.ID(recordName: id.uuidString)
        let record = try await existingRecord(for: recordID)
            ?? CKRecord(recordType: recordType, recordID: recordID)
        guard ((record["modifiedAt"] as? Date) ?? .distantPast) <= date else { return }
        record["deleted"] = NSNumber(value: true)
        record["modifiedAt"] = date as NSDate
        record["snapshot"] = nil
        record["pdf"] = nil
        _ = try await database.save(record)
    }

    private func existingRecord(for id: CKRecord.ID) async throws -> CKRecord? {
        do { return try await database.record(for: id) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        catch { throw error }
    }
}
