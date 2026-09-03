import Foundation
import Photos

@MainActor
final class ModoreViewModel: ObservableObject {
    @Published private(set) var storage: DeviceStorageSnapshot?
    @Published private(set) var media = MediaSummary.empty
    @Published private(set) var isScanning = false

    private let scanner: any PhotoLibraryScanning
    private let storageSnapshot: () -> DeviceStorageSnapshot?
    private let viewLifetimeSuspension: @Sendable () async -> Void
    private var operationTask: Task<Void, Never>?
    private var viewLifetimeGeneration: UInt64 = 0

    init(
        scanner: any PhotoLibraryScanning = PhotoLibraryScanner(),
        storageSnapshot: @escaping () -> DeviceStorageSnapshot? = {
            DeviceStorageSnapshot.current()
        },
        viewLifetimeSuspension: @escaping @Sendable () async -> Void = {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_600_000_000_000)
                } catch {
                    break
                }
            }
        }
    ) {
        self.scanner = scanner
        self.storageSnapshot = storageSnapshot
        self.viewLifetimeSuspension = viewLifetimeSuspension
    }

    deinit {
        operationTask?.cancel()
    }

    var authorization: PhotoAuthorization { media.authorization }

    func refresh() {
        storage = storageSnapshot()
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        operationTask = Task { @MainActor [weak self, scanner] in
            let summary = await scanner.scan()
            guard !Task.isCancelled else { return }
            self?.finish(with: summary)
        }
    }

    func requestPhotoAccess() {
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        operationTask = Task { @MainActor [weak self, scanner] in
            _ = await scanner.requestAuthorization()
            guard !Task.isCancelled else { return }
            let summary = await scanner.scan()
            guard !Task.isCancelled else { return }
            self?.finish(with: summary)
        }
    }

    func refreshForViewLifetime() async {
        guard !Task.isCancelled else { return }
        viewLifetimeGeneration &+= 1
        let generation = viewLifetimeGeneration
        refresh()
        await viewLifetimeSuspension()
        guard generation == viewLifetimeGeneration else { return }
        cancelCurrentOperation()
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
        operationTask = nil
        isScanning = false
    }

    func waitForCurrentOperation() async {
        let task = operationTask
        await task?.value
    }

    private func finish(with summary: MediaSummary) {
        media = summary
        isScanning = false
        operationTask = nil
    }
}
