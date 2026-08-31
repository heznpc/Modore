import Foundation
import Photos

struct MediaCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let duration: TimeInterval
    let createdAt: Date?
    let isScreenRecording: Bool

    var title: String {
        guard let createdAt else { return String(localized: "Video without a date") }
        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }
}

struct MediaSummary: Equatable, Sendable {
    let videoCount: Int
    let videoDuration: TimeInterval
    let screenRecordingCount: Int
    let screenRecordingDuration: TimeInterval
    let longestVideos: [MediaCandidate]
    let authorization: PhotoAuthorization

    static let empty = MediaSummary(
        videoCount: 0,
        videoDuration: 0,
        screenRecordingCount: 0,
        screenRecordingDuration: 0,
        longestVideos: [],
        authorization: .notDetermined
    )
}

enum PhotoAuthorization: String, Equatable, Sendable {
    case notDetermined
    case restricted
    case denied
    case limited
    case authorized

    init(_ status: PHAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .limited: self = .limited
        case .authorized: self = .authorized
        @unknown default: self = .restricted
        }
    }

    var label: String {
        switch self {
        case .notDetermined: return String(localized: "Permission needed")
        case .restricted: return String(localized: "Photo access is restricted")
        case .denied: return String(localized: "Photo access was denied")
        case .limited: return String(localized: "Selected photos only")
        case .authorized: return String(localized: "Photo-library access allowed")
        }
    }
}
