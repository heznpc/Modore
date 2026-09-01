import Foundation
import Photos

struct PhotoVideoAsset: Equatable, Sendable {
    let id: String
    let duration: TimeInterval
    let createdAt: Date?
    let isScreenRecording: Bool
}

protocol PhotoLibraryAccessing: Sendable {
    func authorizationStatus() async -> PhotoAuthorization
    func requestAuthorization() async -> PhotoAuthorization
    func fetchVideoAssets() async -> [PhotoVideoAsset]
}

struct SystemPhotoLibraryAccess: PhotoLibraryAccessing {
    func authorizationStatus() async -> PhotoAuthorization {
        PhotoAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoAuthorization(status)
    }

    func fetchVideoAssets() async -> [PhotoVideoAsset] {
        await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            var snapshots: [PhotoVideoAsset] = []
            snapshots.reserveCapacity(assets.count)
            assets.enumerateObjects { asset, _, _ in
                snapshots.append(PhotoVideoAsset(
                    id: asset.localIdentifier,
                    duration: asset.duration,
                    createdAt: asset.creationDate,
                    isScreenRecording: asset.mediaSubtypes.contains(.videoScreenRecording)
                ))
            }
            return snapshots
        }.value
    }
}

protocol PhotoLibraryScanning: Sendable {
    func requestAuthorization() async -> PhotoAuthorization
    func scan() async -> MediaSummary
}

struct PhotoLibraryScanner: PhotoLibraryScanning {
    private let library: any PhotoLibraryAccessing

    init(library: any PhotoLibraryAccessing = SystemPhotoLibraryAccess()) {
        self.library = library
    }

    func requestAuthorization() async -> PhotoAuthorization {
        await library.requestAuthorization()
    }

    func scan() async -> MediaSummary {
        let authorization = await library.authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return Self.emptySummary(authorization: authorization)
        }
        let assets = await library.fetchVideoAssets()
        return Self.summarize(assets, authorization: authorization)
    }

    private static func summarize(
        _ assets: [PhotoVideoAsset],
        authorization: PhotoAuthorization
    ) -> MediaSummary {
        var videoCount = 0
        var videoDuration: TimeInterval = 0
        var screenRecordingCount = 0
        var screenRecordingDuration: TimeInterval = 0
        var longestVideos: [MediaCandidate] = []

        for asset in assets {
            let candidate = MediaCandidate(
                id: asset.id,
                duration: max(0, asset.duration),
                createdAt: asset.createdAt,
                isScreenRecording: asset.isScreenRecording
            )
            videoCount += 1
            videoDuration += candidate.duration
            if candidate.isScreenRecording {
                screenRecordingCount += 1
                screenRecordingDuration += candidate.duration
            }
            longestVideos.append(candidate)
            longestVideos.sort(by: Self.longerFirst)
            if longestVideos.count > 5 { longestVideos.removeLast() }
        }

        return MediaSummary(
            videoCount: videoCount,
            videoDuration: videoDuration,
            screenRecordingCount: screenRecordingCount,
            screenRecordingDuration: screenRecordingDuration,
            longestVideos: longestVideos,
            authorization: authorization
        )
    }

    private static func emptySummary(authorization: PhotoAuthorization) -> MediaSummary {
        MediaSummary(
            videoCount: 0,
            videoDuration: 0,
            screenRecordingCount: 0,
            screenRecordingDuration: 0,
            longestVideos: [],
            authorization: authorization
        )
    }

    private static func longerFirst(_ lhs: MediaCandidate, _ rhs: MediaCandidate) -> Bool {
        if lhs.duration == rhs.duration { return lhs.id < rhs.id }
        return lhs.duration > rhs.duration
    }
}
