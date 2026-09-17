import Foundation
import Photos

enum CleanupMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case videos, screenRecordings, photos
    var id: Self { self }
    var title: String {
        switch self {
        case .videos: String(localized: "Videos")
        case .screenRecordings: String(localized: "Screen recordings")
        case .photos: String(localized: "Photos")
        }
    }
}

struct CleanupMediaItem: Identifiable, Equatable, Sendable {
    let id: String
    let createdAt: Date?
    let modifiedAt: Date?
    let duration: TimeInterval
    let isVideo: Bool
    let isFavorite: Bool
    let canDelete: Bool

    init(asset: PHAsset) {
        id = asset.localIdentifier
        createdAt = asset.creationDate
        modifiedAt = asset.modificationDate
        duration = asset.duration
        isVideo = asset.mediaType == .video
        isFavorite = asset.isFavorite
        canDelete = asset.canPerform(.delete)
    }

    init(id: String, createdAt: Date? = nil, modifiedAt: Date? = nil, duration: TimeInterval = 0,
         isVideo: Bool = true, isFavorite: Bool = false, canDelete: Bool = true) {
        self.id = id
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.duration = duration
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.canDelete = canDelete
    }

    var title: String {
        createdAt?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Item without a date")
    }
}

protocol PhotoCleanupServicing: Sendable {
    func load(filter: CleanupMediaFilter) async throws -> [CleanupMediaItem]
    func delete(_ selection: [CleanupMediaItem]) async throws
}

struct PhotoCleanupService: PhotoCleanupServicing {
    func load(filter: CleanupMediaFilter) async throws -> [CleanupMediaItem] {
        try Self.requireAccess()
        return await PhotoLibraryWorker.run {
            let options = PHFetchOptions()
            options.fetchLimit = 200
            options.sortDescriptors = [NSSortDescriptor(
                key: filter == .photos ? "creationDate" : "duration", ascending: false
            )]
            if filter == .screenRecordings {
                options.predicate = NSPredicate(
                    format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.videoScreenRecording.rawValue
                )
            }
            let assets = PHAsset.fetchAssets(with: filter == .photos ? .image : .video, options: options)
            var items: [CleanupMediaItem] = []
            assets.enumerateObjects { asset, _, stop in
                if Task.isCancelled { stop.pointee = true; return }
                items.append(CleanupMediaItem(asset: asset))
            }
            return items
        }
    }

    func delete(_ selection: [CleanupMediaItem]) async throws {
        try Task.checkCancellation()
        try Self.requireAccess()
        let expected = Dictionary(selection.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard !expected.isEmpty else { throw CleanupError.emptySelection }
        let validation = PhotoDeletionValidation()
        // Re-fetch inside the change block; never silently delete a surviving
        // subset if permission, availability, or the selected content changed.
        try await PHPhotoLibrary.shared().performChanges {
            let assets = PHAsset.fetchAssets(withLocalIdentifiers: Array(expected.keys), options: nil)
            var current: [CleanupMediaItem] = []
            assets.enumerateObjects { asset, _, _ in
                current.append(CleanupMediaItem(asset: asset))
            }
            if Self.selectionIsCurrent(Array(expected.values), current: current) {
                validation.accept()
                PHAssetChangeRequest.deleteAssets(assets)
            }
        }
        // PhotoKit can complete a no-op block successfully. Only an accepted
        // change request followed by successful completion counts as deletion.
        guard validation.accepted else { throw CleanupError.selectionChanged }
    }

    static func selectionIsCurrent(_ expected: [CleanupMediaItem], current: [CleanupMediaItem]) -> Bool {
        guard !expected.isEmpty, expected.count == current.count,
              Set(expected.map(\.id)).count == expected.count else { return false }
        let lookup = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return expected.allSatisfy { $0.canDelete && lookup[$0.id] == $0 }
    }

    private static func requireAccess() throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { throw CleanupError.accessDenied }
    }
}

private final class PhotoDeletionValidation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func accept() { lock.withLock { value = true } }
    var accepted: Bool { lock.withLock { value } }
}

struct MediaDeletionPlan: Identifiable {
    let id = UUID()
    let items: [CleanupMediaItem]
}

@MainActor
final class PhotoCleanupModel: ObservableObject {
    @Published private(set) var items: [CleanupMediaItem] = []
    @Published private(set) var selection: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isDeleting = false
    @Published var errorMessage: String?
    private let service: any PhotoCleanupServicing
    private let capacity: () -> DeviceStorageSnapshot?
    private var generation = 0

    init(service: any PhotoCleanupServicing = PhotoCleanupService(),
         capacity: @escaping () -> DeviceStorageSnapshot? = { DeviceStorageSnapshot.current() }) {
        self.service = service
        self.capacity = capacity
    }

    func load(filter: CleanupMediaFilter) async {
        guard !isDeleting else { return }
        generation += 1
        let current = generation
        isLoading = true
        items = []
        selection = []
        errorMessage = nil
        defer { if current == generation { isLoading = false } }
        do {
            let loaded = try await service.load(filter: filter)
            guard !Task.isCancelled, current == generation else { return }
            items = loaded
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    func toggle(_ item: CleanupMediaItem) {
        guard !isDeleting, !isLoading, item.canDelete, items.contains(item) else { return }
        if !selection.insert(item.id).inserted { selection.remove(item.id) }
    }

    func plan() -> MediaDeletionPlan? {
        let selected = items.filter { selection.contains($0.id) && $0.canDelete }
        guard !selected.isEmpty, !isDeleting, !isLoading else { return nil }
        return MediaDeletionPlan(items: selected)
    }

    func delete(_ plan: MediaDeletionPlan, history: CleanupHistory, filter: CleanupMediaFilter) async {
        guard !isDeleting, !isLoading else { return }
        guard !plan.items.isEmpty, plan.items.allSatisfy({ items.contains($0) && selection.contains($0.id) }) else {
            errorMessage = CleanupError.selectionChanged.localizedDescription
            return
        }
        isDeleting = true
        errorMessage = nil
        var receiptID: UUID?
        do {
            let id = try history.begin(kind: .media, count: plan.items.count, beforeBytes: capacity()?.availableBytes)
            receiptID = id
            try await service.delete(plan.items)
            history.finish(id: id, deletedCount: plan.items.count, status: .completed, afterBytes: capacity()?.availableBytes)
        } catch {
            let nsError = error as NSError
            let cancelled = (nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.Code.userCancelled.rawValue)
                || error is CancellationError
            if let receiptID {
                history.finish(id: receiptID, deletedCount: 0, status: cancelled ? .cancelled : .failed,
                               afterBytes: capacity()?.availableBytes)
            }
            errorMessage = cancelled ? String(localized: "Deletion cancelled.") : error.localizedDescription
        }
        isDeleting = false
        let deletionMessage = errorMessage
        await load(filter: filter)
        if let deletionMessage { errorMessage = deletionMessage }
    }
}
