import Foundation

enum ModoreRoute: Equatable, Sendable {
    case health
    case storageRecovery
    case quotaTask(String)

    init?(url: URL) {
        if url.absoluteString.lowercased() == "modore://health" {
            self = .health
            return
        }
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.scheme?.lowercased() == "modore", parts.host?.lowercased() == "work",
           parts.user == nil, parts.password == nil, parts.port == nil,
           parts.percentEncodedQuery == nil, parts.percentEncodedFragment == nil,
           parts.percentEncodedPath == parts.path,
           parts.path.hasPrefix("/quota-task/"), parts.path.count == 48,
           let id = UUID(uuidString: String(parts.path.dropFirst(12))) {
            self = .quotaTask(id.uuidString.lowercased())
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
        case .health, .quotaTask: return false
        case .storageRecovery:
            // Existing candidates go straight to bounded, per-target previews.
            // A full scan is needed only when there is no inventory to review.
            return !hasStorageData && !isBusy
        }
    }
}
