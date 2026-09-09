import Foundation
struct WorkResourceSnapshot: Decodable {
    let observedAt: Double
    let resources: [WorkResource]
    let warnings: [String]
    let coverage: String
}
struct WorkResource: Decodable, Identifiable {
    let id, kind, name, runtime, deviceType, state, path, fingerprint: String
    let available, preferred: Bool
    let duplicates: [String]
    let leases, expiredLeases: [ResourceLease]
    let processes: [ResourceProcess]
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
