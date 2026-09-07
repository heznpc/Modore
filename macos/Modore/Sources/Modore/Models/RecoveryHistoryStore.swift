import Foundation

/// One bounded, atomically replaced private document. Corrupt/unsupported
/// history is never silently replaced with an empty ledger. No automatic purge.
enum RecoveryHistoryStore {
    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumRecords = 200

    private struct Document: Codable {
        let version: Int
        var records: [RecoveryHistory]
    }

    enum Failure: Error { case invalidHistory, capacityReached }

    static func url(in root: URL) -> URL { root.appendingPathComponent("recovery-history.json") }

    static func load(in root: URL, expectedParentIdentity: FilesystemIdentity? = nil) throws -> [RecoveryHistory] {
        let data: Data
        do {
            data = try SecureLocalFileIO.boundedRead(from: url(in: root), maximumBytes: maximumBytes,
                                                    requireCurrentOwner: true,
                                                    expectedParentIdentity: expectedParentIdentity)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == 2 {
            return []
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1, document.records.count <= maximumRecords,
              Set(document.records.map(\.id)).count == document.records.count,
              document.records.allSatisfy(valid) else { throw Failure.invalidHistory }
        return document.records.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    static func save(_ record: RecoveryHistory, in root: URL) throws -> [RecoveryHistory] {
        guard valid(record) else { throw Failure.invalidHistory }
        try SecureLocalFileIO.ensurePrivateDirectory(root)
        guard let identity = FilesystemIdentity.directory(at: root) else { throw Failure.invalidHistory }
        var records = try load(in: root, expectedParentIdentity: identity)
        records.removeAll { $0.id == record.id }
        records.insert(record, at: 0)
        guard records.count <= maximumRecords else { throw Failure.capacityReached }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Document(version: 1, records: records))
        guard data.count <= maximumBytes else { throw Failure.capacityReached }
        try SecureLocalFileIO.atomicWrite(data, to: url(in: root), expectedParentIdentity: identity)
        return records.sorted { $0.createdAt > $1.createdAt }
    }

    private static func valid(_ record: RecoveryHistory) -> Bool {
        let ids = Set(record.entries.map(\.id))
        return record.requestedGainBytes > 0 && record.desiredFreeBytes != nil
            && (record.finalFreeBytes.map { $0 >= 0 } ?? true)
            && record.entries.count <= 500 && ids.count == record.entries.count
            && record.items.count <= record.entries.count
            && Set(record.items.map(\.id)).count == record.items.count
            && record.items.allSatisfy { ids.contains($0.id) }
            && (record.activeEntryID.map { ids.contains($0) } ?? true)
            && record.entries.allSatisfy { $0.targets.count <= 500 }
    }
}
