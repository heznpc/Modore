import Foundation

enum ModoreRoute: Equatable, Sendable {
    case health
    case storageRecovery

    init?(url: URL) {
        if url.absoluteString.lowercased() == "modore://health" {
            self = .health
            return
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ),
        components.scheme?.lowercased() == "modore",
        components.host?.lowercased() == "storage",
        components.user == nil,
        components.password == nil,
        components.port == nil,
        components.percentEncodedPath == "/recovery",
        components.percentEncodedQuery == nil,
        components.percentEncodedFragment == nil else {
            return nil
        }

        self = .storageRecovery
    }

    func shouldStartStorageScan(hasStorageData: Bool, isBusy: Bool) -> Bool {
        switch self {
        case .health: return false
        case .storageRecovery:
            // Existing candidates go straight to bounded, per-target previews.
            // A full scan is needed only when there is no inventory to review.
            return !hasStorageData && !isBusy
        }
    }
}
