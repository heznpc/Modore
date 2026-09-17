import Foundation

struct CleanupFileItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let location: String
    let bytes: Int64
}

struct FileCleanupPreview: Sendable {
    let items: [CleanupFileItem]
    let rejectedCount: Int
}

struct FileCleanupOutcome: Sendable {
    let deletedCount: Int
    let errorMessage: String?
}

/// Retains security-scoped access only for the current, explicitly picked files.
/// Coordination and metadata reads run on this actor, away from the UI executor.
actor FileCleanupService {
    private struct Fingerprint: Equatable {
        let bytes: Int64
        let modifiedAt: Date
        let resourceID: String
        let resolvedPath: String
    }
    private struct Entry {
        let url: URL
        let scoped: Bool
        let fingerprint: Fingerprint
    }
    private var entries: [UUID: Entry] = [:]

    func preview(_ urls: [URL]) -> FileCleanupPreview {
        release()
        var items: [CleanupFileItem] = []
        var rejected = 0
        var seen = Set<String>()
        for url in urls.prefix(100) {
            guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
            let scoped = url.startAccessingSecurityScopedResource()
            do {
                let fingerprint = try coordinatedFingerprint(url)
                let id = UUID()
                entries[id] = Entry(url: url, scoped: scoped, fingerprint: fingerprint)
                items.append(CleanupFileItem(id: id, name: url.lastPathComponent,
                                             location: url.deletingLastPathComponent().lastPathComponent,
                                             bytes: fingerprint.bytes))
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                rejected += 1
            }
        }
        rejected += max(0, urls.count - 100)
        return FileCleanupPreview(items: items.sorted { $0.bytes > $1.bytes }, rejectedCount: rejected)
    }

    func delete(ids: [UUID]) -> FileCleanupOutcome {
        let uniqueIDs = Array(Set(ids))
        guard !uniqueIDs.isEmpty else {
            return FileCleanupOutcome(deletedCount: 0, errorMessage: CleanupError.emptySelection.localizedDescription)
        }
        // Preflight the entire plan so stale selection does not cause a partial
        // deletion. Recheck again under each coordinated write for races.
        do {
            for id in uniqueIDs {
                guard let entry = entries[id], try coordinatedFingerprint(entry.url) == entry.fingerprint else {
                    throw CleanupError.selectionChanged
                }
            }
        } catch {
            return FileCleanupOutcome(deletedCount: 0, errorMessage: CleanupError.selectionChanged.localizedDescription)
        }
        var deleted = 0
        for id in uniqueIDs {
            guard let entry = entries[id] else { continue }
            do {
                var coordinationError: NSError?
                var operationError: Error?
                var didDelete = false
                NSFileCoordinator().coordinate(writingItemAt: entry.url, options: .forDeleting,
                                               error: &coordinationError) { coordinatedURL in
                    do {
                        guard try Self.fingerprint(coordinatedURL) == entry.fingerprint else {
                            throw CleanupError.selectionChanged
                        }
                        try FileManager.default.removeItem(at: coordinatedURL)
                        didDelete = true
                    } catch { operationError = error }
                }
                if let error = operationError ?? coordinationError { throw error }
                guard didDelete else { throw CleanupError.accessDenied }
                deleted += 1
                if entry.scoped { entry.url.stopAccessingSecurityScopedResource() }
                entries.removeValue(forKey: id)
            } catch {
                return FileCleanupOutcome(deletedCount: deleted, errorMessage: String(localized: "Some files could not be deleted. Select the remaining files again."))
            }
        }
        return FileCleanupOutcome(deletedCount: deleted, errorMessage: nil)
    }

    func release() {
        for entry in entries.values where entry.scoped { entry.url.stopAccessingSecurityScopedResource() }
        entries = [:]
    }

    private func coordinatedFingerprint(_ url: URL) throws -> Fingerprint {
        var coordinationError: NSError?
        var result: Result<Fingerprint, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges,
                                       error: &coordinationError) { coordinatedURL in
            result = Result { try Self.fingerprint(coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CleanupError.accessDenied }
        return try result.get()
    }

    private static func fingerprint(_ url: URL) throws -> Fingerprint {
        guard url.isFileURL else { throw CleanupError.unsupportedFile }
        // Foundation caches resource values on URL. A fresh coordinated read
        // must invalidate those values or replaced/edited files look unchanged.
        var freshURL = url
        freshURL.removeAllCachedResourceValues()
        let values = try freshURL.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
            .fileResourceIdentifierKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0,
              let modified = values.contentModificationDate,
              let identifier = values.fileResourceIdentifier else { throw CleanupError.unsupportedFile }
        if values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current,
           values.ubiquitousItemDownloadingStatus != .downloaded {
            throw CleanupError.unsupportedFile
        }
        return Fingerprint(bytes: Int64(size), modifiedAt: modified,
                           resourceID: String(describing: identifier),
                           resolvedPath: freshURL.resolvingSymlinksInPath().path)
    }
}

struct FileDeletionPlan: Identifiable {
    let id = UUID()
    let items: [CleanupFileItem]
}

@MainActor
final class FileCleanupModel: ObservableObject {
    @Published private(set) var items: [CleanupFileItem] = []
    @Published private(set) var selection: Set<UUID> = []
    @Published private(set) var isBusy = false
    @Published var message: String?
    private let service = FileCleanupService()

    func preview(_ urls: [URL]) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        let result = await service.preview(urls)
        items = result.items
        selection = []
        if result.rejectedCount > 0 {
            message = String(localized: "Some items were excluded. Choose up to 100 available regular files.")
        }
        isBusy = false
    }

    func toggle(_ item: CleanupFileItem) {
        guard !isBusy, items.contains(item) else { return }
        if !selection.insert(item.id).inserted { selection.remove(item.id) }
    }

    func plan() -> FileDeletionPlan? {
        let selected = items.filter { selection.contains($0.id) }
        guard !selected.isEmpty, !isBusy else { return nil }
        return FileDeletionPlan(items: selected)
    }

    func delete(_ plan: FileDeletionPlan, history: CleanupHistory) async {
        guard !isBusy else { return }
        guard !plan.items.isEmpty, plan.items.allSatisfy({ items.contains($0) && selection.contains($0.id) }) else {
            message = CleanupError.selectionChanged.localizedDescription
            return
        }
        isBusy = true
        do {
            let id = try history.begin(kind: .files, count: plan.items.count,
                                       beforeBytes: DeviceStorageSnapshot.current()?.availableBytes)
            let outcome = await service.delete(ids: plan.items.map(\.id))
            let status: CleanupReceipt.Status = outcome.errorMessage == nil ? .completed
                : (outcome.deletedCount == 0 ? .failed : .partial)
            history.finish(id: id, deletedCount: outcome.deletedCount, status: status,
                           afterBytes: DeviceStorageSnapshot.current()?.availableBytes)
            message = outcome.errorMessage ?? String(localized: "Selected files deleted. Check the measured available space below.")
        } catch {
            message = String(localized: "Cleanup could not start because its receipt could not be saved.")
        }
        await service.release()
        items = []
        selection = []
        isBusy = false
    }

    func close() async { await service.release() }
}
