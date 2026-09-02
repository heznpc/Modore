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

    func shouldStartStorageScan(hasStorageData _: Bool, isBusy: Bool) -> Bool {
        switch self {
        case .storageRecovery:
            // Recovery is an explicit request for the disk's current state.
            // A previously loaded report may predate the growth incident by
            // days, so its mere presence must not suppress remeasurement.
            return !isBusy
        }
    }
}
