import Foundation

/// Standing consent describes the scope the person saw, not the last policy run.
struct AutomaticCacheConsent: Codable, Equatable {
    var schemaVersion = 1
    let acceptedAt: Date
    let recipeVersions: [String: Int]

    func authorizes(_ scope: [String: Int]) -> Bool {
        schemaVersion == 1 && !scope.isEmpty && scope.allSatisfy {
            recipeVersions[$0.key] == $0.value
        }
    }
}

enum AutomaticCacheConsentStore {
    static let enabledKey = "automaticSafeCacheRecovery"
    static let consentKey = "automaticSafeCacheRecoveryConsent"

    enum Status: Equatable {
        case disabled, reviewRequired, authorized
    }

    static func status(in defaults: UserDefaults, scope: [String: Int] = AutomaticCachePolicy.consentScope) -> Status {
        guard defaults.bool(forKey: enabledKey) else { return .disabled }
        guard let data = defaults.data(forKey: consentKey),
              let consent = try? JSONDecoder().decode(AutomaticCacheConsent.self, from: data),
              consent.authorizes(scope) else { return .reviewRequired }
        return .authorized
    }

    static func isAuthorized(in defaults: UserDefaults = .standard) -> Bool {
        status(in: defaults) == .authorized
    }

    static func grant(in defaults: UserDefaults, now: Date = Date()) throws {
        let consent = AutomaticCacheConsent(acceptedAt: now, recipeVersions: AutomaticCachePolicy.consentScope)
        let data = try JSONEncoder().encode(consent)
        defaults.set(data, forKey: consentKey)
        defaults.set(true, forKey: enabledKey)
    }

    static func revoke(in defaults: UserDefaults) {
        defaults.set(false, forKey: enabledKey)
        defaults.removeObject(forKey: consentKey)
    }
}
