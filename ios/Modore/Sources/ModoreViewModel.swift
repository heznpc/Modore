import Foundation
import Photos

@MainActor
final class ModoreViewModel: ObservableObject {
    @Published private(set) var storage: DeviceStorageSnapshot?
    @Published private(set) var media = MediaSummary.empty
    @Published private(set) var isScanning = false

    private let scanner: any PhotoLibraryScanning
    private let storageSnapshot: () -> DeviceStorageSnapshot?
    private var operationTask: Task<Void, Never>?

    init(
        scanner: any PhotoLibraryScanning = PhotoLibraryScanner(),
        storageSnapshot: @escaping () -> DeviceStorageSnapshot? = {
            DeviceStorageSnapshot.current()
        }
    ) {
        self.scanner = scanner
        self.storageSnapshot = storageSnapshot
    }

    var authorization: PhotoAuthorization { media.authorization }

    func refresh() {
        storage = storageSnapshot()
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        operationTask = Task { @MainActor [weak self, scanner] in
            let summary = await scanner.scan()
            self?.finish(with: summary)
        }
    }

    func requestPhotoAccess() {
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        operationTask = Task { @MainActor [weak self, scanner] in
            _ = await scanner.requestAuthorization()
            let summary = await scanner.scan()
            self?.finish(with: summary)
        }
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
