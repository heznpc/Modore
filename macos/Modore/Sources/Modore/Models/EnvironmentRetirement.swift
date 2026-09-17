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
    var actionLabel: String {
        switch kind { case "registration": return L10n.text("등록 해제 · 파일 유지"); case "process","vm": return L10n.text("정상 종료"); case "volume": return L10n.text("추출"); default:return L10n.text("삭제") }
    }
    var displayName: String { kind == "registration" ? URL(fileURLWithPath:path).lastPathComponent : name }
    var subtitle: String {
        let states = ["Shutdown":L10n.text("꺼짐"), "Running":L10n.text("실행 중"), "Booted":L10n.text("실행 중"), "Ready":L10n.text("설치됨"), "Mounted":L10n.text("연결됨")]
        let stateText = states[state] ?? state
        let projectText = project.isEmpty ? "" : " · " + URL(fileURLWithPath:project).lastPathComponent
        return L10n.text(platform) + " · " + stateText + projectText
    }
    var finished: Bool { mutation == "succeeded" }
    var icon: String {
        switch kind {
        case "registration": return "app.dashed"
        case "runtime": return "shippingbox"
        case "cache": return "arrow.triangle.2.circlepath"
        case "process": return "terminal"
        case "vm": return "server.rack"
        case "volume": return "externaldrive"
        default: return platform == "watchOS" ? "applewatch" : (platform == "iPadOS" ? "ipad" : "iphone")
        }
    }
}
