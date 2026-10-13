import Foundation
struct ResourceSessionIdentity: Equatable {
    let provider, session: String
}
struct ResourceConnectionRequest: Encodable {
    let action: String
    let id, fingerprint, project, session, provider: String

    init(id: String, fingerprint: String, project: String, identity: ResourceSessionIdentity, isSimulator: Bool = true) {
        action = isSimulator ? "bind" : "claim"
        self.id = id; self.fingerprint = fingerprint; self.project = project
        self.session = identity.session; self.provider = identity.provider
    }

    var dictionary: [String: Any] {
        ["action": action, "id": id, "fingerprint": fingerprint,
         "project": project, "session": session, "provider": provider]
    }
}
extension SessionIndexEntry {
    var resourceIdentity: ResourceSessionIdentity? {
        guard let session = providerSessionId, !session.isEmpty else { return nil }
        return ResourceSessionIdentity(provider: tool.lowercased(), session: session)
    }
}
struct WorkResourceSnapshot: Decodable {
    let observedAt: Double
    let resources: [WorkResource]
    let warnings: [String]
    let coverage: String
    let hookStatus: [WorkResourceHookStatus]?
}
struct WorkResourceHookStatus: Decodable, Identifiable {
    var id: String { provider }
    let provider: String
    let configured, disabled, recentlyObserved: Bool
    let lastObservedAt: Double?
    let lastEvent, error: String?
    let trustStatus, lastSession: String?
    let simulatorGuard: ResourceGuardStatus?
}
struct ResourceGuardStatus: Decodable {
    let configured, hostEnforcementVerified: Bool
    let coverage: String
}
struct ResourceBinding: Decodable, Identifiable {
    var id: String { provider + ":" + session + ":" + project + ":" + resourceID }
    let provider, session, project, resourceID: String
}
struct WorkResource: Decodable, Identifiable {
    let id, kind, name, runtime, deviceType, state, path, fingerprint: String
    let available, preferred: Bool
    let duplicates: [String]
    let leases, expiredLeases: [ResourceLease]
    let processes: [ResourceProcess]
    let bindings: [ResourceBinding]?
}
struct ResourceLease: Decodable, Identifiable {
    var id: String { session + resourceID }
    let resourceID, session, project: String
    let updatedAt, expiresAt: Double
}
struct ResourceProcess: Decodable, Identifiable {
    var id: Int { pid }
    let pid: Int
    let name, cwd: String
}
