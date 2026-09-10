import Foundation

struct EnvironmentCapacity: Decodable {
    let totalBytes, freeBytes: Int64
    let observedAt: Double
}
struct EnvironmentPolicy: Decodable {
    let platforms: [String]
    let requirements: [EnvironmentRequirement]
    let scheduleEnabled: Bool
    let intervalHours, minimumFreeGB: Double
    let cacheIDs: [String]
    let nextRunAt: Double?
    let lastStatus: String?
}
struct EnvironmentRequirement: Decodable {
    let project, platform, runtime: String
}
struct EnvironmentPlan: Decodable {
    let id: String
    let createdAt: Double
    let items: [EnvironmentItem]
    let before: EnvironmentCapacity
    let after: EnvironmentCapacity?
    let memoryBefore, memoryAfter: String
    let warnings, missingPlatforms: [String]
    let policy: EnvironmentPolicy
    let cacheBytes: Int64?
    let cancelled: Bool
}
struct EnvironmentItem: Decodable, Identifiable {
    let id, target, kind, name, platform, runtime, state, path, project, fingerprint: String
    let bytes: Int64?
    let warnings: [String]
    let invariant: String
    let approved, changed: Bool
    let mutation, verification, error: String
    var subtitle: String {
        let states = ["Shutdown":"꺼짐", "Running":"실행 중", "Booted":"실행 중", "Ready":"설치됨", "Mounted":"연결됨"]
        let stateText = states[state] ?? state
        let projectText = project.isEmpty ? "" : " · " + URL(fileURLWithPath:project).lastPathComponent
        return platform + " · " + stateText + projectText
    }
    var finished: Bool { mutation == "succeeded" }
    var icon: String {
        switch kind {
        case "runtime": return "shippingbox"
        case "cache": return "arrow.triangle.2.circlepath"
        case "process": return "terminal"
        case "vm": return "server.rack"
        case "volume": return "externaldrive"
        default: return platform == "watchOS" ? "applewatch" : (platform == "iPadOS" ? "ipad" : "iphone")
        }
    }
}
