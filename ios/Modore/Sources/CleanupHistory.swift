import Foundation

struct CleanupReceipt: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case media, files }
    enum Status: String, Codable { case inProgress, completed, partial, failed, cancelled }

    let id: UUID
    let kind: Kind
    let requestedCount: Int
    let startedAt: Date
    let beforeBytes: Int64?
    var deletedCount: Int = 0
    var status: Status = .inProgress
    var afterBytes: Int64?
    var finishedAt: Date?

    var availableChange: Int64? {
        guard let beforeBytes, let afterBytes else { return nil }
        return afterBytes - beforeBytes
    }
}

/// Receipts contain counts and device capacity, never media identifiers or file paths.
@MainActor
final class CleanupHistory: ObservableObject {
    @Published private(set) var receipts: [CleanupReceipt] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var activeReceipts: Set<UUID> = []
    private let url: URL

    init(url: URL = URL.applicationSupportDirectory.appendingPathComponent("cleanup-history.json")) {
        self.url = url
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                receipts = try JSONDecoder().decode([CleanupReceipt].self, from: Data(contentsOf: url))
            }
        } catch {
            errorMessage = String(localized: "Cleanup history could not be read.")
        }
    }

    func begin(kind: CleanupReceipt.Kind, count: Int, beforeBytes: Int64?) throws -> UUID {
        let receipt = CleanupReceipt(
            id: UUID(), kind: kind, requestedCount: count, startedAt: Date(), beforeBytes: beforeBytes
        )
        try save(Array(([receipt] + receipts).prefix(20)))
        activeReceipts.insert(receipt.id)
        return receipt.id
    }

    func finish(id: UUID, deletedCount: Int, status: CleanupReceipt.Status, afterBytes: Int64?) {
        guard let index = receipts.firstIndex(where: { $0.id == id }) else { return }
        activeReceipts.remove(id)
        var updated = receipts
        updated[index].deletedCount = deletedCount
        updated[index].status = status
        updated[index].afterBytes = afterBytes
        updated[index].finishedAt = Date()
        do {
            try save(updated)
        } catch {
            // Keep the real outcome visible even if persistence fails. The on-disk
            // in-progress receipt remains evidence that the operation was started.
            receipts = updated
            errorMessage = String(localized: "The cleanup result could not be saved.")
        }
    }

    private func save(_ updated: [CleanupReceipt]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        receipts = updated
        errorMessage = nil
    }
}

enum CleanupError: LocalizedError {
    case accessDenied, selectionChanged, unsupportedFile, emptySelection

    var errorDescription: String? {
        switch self {
        case .accessDenied: String(localized: "Access is unavailable. Check permissions and select the items again.")
        case .selectionChanged: String(localized: "An item changed or is no longer accessible. Review a fresh selection before deleting.")
        case .unsupportedFile: String(localized: "Only regular files can be selected. Folders, links, and unavailable cloud files are excluded.")
        case .emptySelection: String(localized: "Select at least one item.")
        }
    }
}
