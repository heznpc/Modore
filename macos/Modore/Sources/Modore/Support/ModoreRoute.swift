import Foundation

enum ModoreRoute: Equatable, Sendable {
    case storageRecovery

    init?(url: URL) {
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
        case .storageRecovery:
            return !hasStorageData && !isBusy
        }
    }
}
