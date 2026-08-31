import Foundation
import Photos

@MainActor
final class ModoreViewModel: ObservableObject {
    @Published private(set) var storage: DeviceStorageSnapshot?
    @Published private(set) var media = MediaSummary.empty
    @Published private(set) var isScanning = false

    private let scanner: PhotoLibraryScanner

    init(scanner: PhotoLibraryScanner = PhotoLibraryScanner()) {
        self.scanner = scanner
    }

    var authorization: PhotoAuthorization { media.authorization }

    func refresh() {
        storage = DeviceStorageSnapshot.current()
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        Task { @MainActor in
            media = await scanner.scan()
            isScanning = false
        }
    }

    func requestPhotoAccess() {
        guard !isScanning else { return }
        isScanning = true
        let scanner = self.scanner
        Task { @MainActor in
            _ = await scanner.requestAuthorization()
            media = await scanner.scan()
            isScanning = false
        }
    }
}
