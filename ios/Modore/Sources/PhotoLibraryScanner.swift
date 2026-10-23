import Foundation
import Photos

struct PhotoLibraryScanner: Sendable {
    func authorizationStatus() -> PhotoAuthorization {
        PhotoAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoAuthorization(status)
    }

    func scan() async -> MediaSummary {
        await Task.detached(priority: .userInitiated) {
            scanSynchronously()
        }.value
    }

    private func scanSynchronously() -> MediaSummary {
        let authorization = authorizationStatus()
        guard authorization == .authorized || authorization == .limited else {
            return MediaSummary(
                videoCount: 0,
                videoDuration: 0,
                screenRecordingCount: 0,
                screenRecordingDuration: 0,
                longestVideos: [],
                authorization: authorization
            )
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: .video, options: options)
        var videoCount = 0
        var videoDuration: TimeInterval = 0
        var screenRecordingCount = 0
        var screenRecordingDuration: TimeInterval = 0
        var longestVideos: [MediaCandidate] = []

        assets.enumerateObjects { asset, _, _ in
            let candidate = MediaCandidate(
                id: asset.localIdentifier,
                duration: max(0, asset.duration),
                createdAt: asset.creationDate,
                isScreenRecording: asset.mediaSubtypes.contains(.videoScreenRecording)
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

    private static func longerFirst(_ lhs: MediaCandidate, _ rhs: MediaCandidate) -> Bool {
        if lhs.duration == rhs.duration { return lhs.id < rhs.id }
        return lhs.duration > rhs.duration
    }
}
