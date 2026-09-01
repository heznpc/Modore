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
    func summarizeVideoAssets(authorization: PhotoAuthorization) async -> MediaSummary
}

enum PhotoLibraryWorker {
    /// PhotoKit's synchronous fetch has no cancellation API. Keep it off the
    /// caller's executor and propagate cancellation to the worker so it stops
    /// before enumeration, or at the next asset if fetch has already returned.
    static func run<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        let worker = Task.detached(priority: .userInitiated, operation: operation)
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}

struct PhotoVideoSummaryAccumulator: Sendable {
    private(set) var videoCount = 0
    private(set) var videoDuration: TimeInterval = 0
    private(set) var screenRecordingCount = 0
    private(set) var screenRecordingDuration: TimeInterval = 0
    private var longestVideos: [MediaCandidate] = []

    var retainedCandidateCount: Int { longestVideos.count }

    @discardableResult
    mutating func consume(_ asset: PhotoVideoAsset) -> Bool {
        guard !Task.isCancelled else { return false }
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
        return true
    }

    func summary(authorization: PhotoAuthorization) -> MediaSummary {
        MediaSummary(
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

struct SystemPhotoLibraryAccess: PhotoLibraryAccessing {
    func authorizationStatus() async -> PhotoAuthorization {
        PhotoAuthorization(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotoAuthorization {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return PhotoAuthorization(status)
    }

    func summarizeVideoAssets(authorization: PhotoAuthorization) async -> MediaSummary {
        await PhotoLibraryWorker.run {
            var accumulator = PhotoVideoSummaryAccumulator()
            guard !Task.isCancelled else {
                return accumulator.summary(authorization: authorization)
            }
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let assets = PHAsset.fetchAssets(with: .video, options: options)
            guard !Task.isCancelled else {
                return accumulator.summary(authorization: authorization)
            }
            assets.enumerateObjects { asset, _, stop in
                let consumed = accumulator.consume(PhotoVideoAsset(
                    id: asset.localIdentifier,
                    duration: asset.duration,
                    createdAt: asset.creationDate,
                    isScreenRecording: asset.mediaSubtypes.contains(.videoScreenRecording)
                ))
                if !consumed {
                    stop.pointee = true
                }
            }
            return accumulator.summary(authorization: authorization)
        }
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
        return await library.summarizeVideoAssets(authorization: authorization)
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
}
