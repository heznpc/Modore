import Foundation

enum ModoreRoute: Equatable, Sendable {
    case ci
    case betaCue
    case health
    case healthResources(HealthResourceFocus)
    case storageRecovery
    case storageRecoveryResult
    case quotaTask(String)
    case session(WorkSessionLink)

    init?(url: URL) {
        if let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.scheme?.lowercased() == "modore", parts.host?.lowercased() == "work",
           parts.user == nil, parts.password == nil, parts.port == nil,
           parts.percentEncodedQuery == nil, parts.percentEncodedFragment == nil,
           parts.percentEncodedPath == parts.path {
            let path = parts.path.split(separator: "/", omittingEmptySubsequences: false)
            if path.count == 4, path[0].isEmpty, path[1] == "session",
               let link = WorkSessionLink(provider: String(path[2]), sessionID: String(path[3])) {
                self = .session(link)
                return
            }
        }
        if url.absoluteString.lowercased() == "modore://storage/result" {
            self = .storageRecoveryResult
            return
        }
        if url.absoluteString.lowercased() == "modore://work/betacue" {
            self = .betaCue
            return
        }
        if url.absoluteString.lowercased() == "modore://work/ci" {
            self = .ci
            return
        }
        if url.absoluteString.lowercased() == "modore://health" {
            self = .health
            return
        }
        for focus in [HealthResourceFocus.memory, .cpu] {
            if url.absoluteString.lowercased() == "modore://health/\(focus.rawValue)" {
                self = .healthResources(focus)
                return
            }
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
        case .health, .healthResources, .storageRecoveryResult, .quotaTask, .session, .ci, .betaCue: return false
        case .storageRecovery:
            // Existing candidates go straight to bounded, per-target previews.
            // A full scan is needed only when there is no inventory to review.
            return !hasStorageData && !isBusy
        }
    }
}
