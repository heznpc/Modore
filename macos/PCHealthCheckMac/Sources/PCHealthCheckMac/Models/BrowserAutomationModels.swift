import Foundation

struct BrowserAutomationProcess: Equatable, Sendable {
    let pid: Int
    let parentPid: Int
    let elapsed: String
    let memoryKB: Int
    let command: String
}

struct BrowserAutomationClassification: Equatable, Sendable {
    let channel: String
    let profile: String
    let canStop: Bool
}

struct BrowserAutomationProcessIdentity: Equatable, Sendable {
    let pid: Int
    let parentPid: Int
    let startTime: String
    let executablePath: String
    let command: String
}

struct BrowserAutomationStopPreview: Identifiable, Equatable, Sendable {
    let id: UUID
    let identity: BrowserAutomationProcessIdentity
    let elapsed: String
    let channel: String
    let profile: String
    let controller: String
    let rootMemoryKB: Int
    let treeMemoryKB: Int
    let processCount: Int

    var pid: Int { identity.pid }
    var parentPid: Int { identity.parentPid }

    var rootMemoryText: String {
        Self.memoryText(rootMemoryKB)
    }

    var treeMemoryText: String {
        Self.memoryText(treeMemoryKB)
    }

    private static func memoryText(_ value: Int) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(max(0, value)) * 1024,
            countStyle: .memory
        )
    }
}

enum BrowserAutomationStopError: LocalizedError, Equatable {
    case unavailable
    case targetGone
    case targetChanged
    case protectedProfile
    case signalFailed
    case stillRunning

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "실행 중인 프로세스를 제한 시간 안에 확인하지 못했습니다. 아무것도 종료하지 않았습니다."
        case .targetGone:
            return "검토한 자동화 브라우저가 이미 종료되었습니다. 아무것도 추가로 종료하지 않았습니다."
        case .targetChanged:
            return "PID의 실행 주체가 검토 이후 바뀌어 종료하지 않았습니다. 다시 검사해 주세요."
        case .protectedProfile:
            return "일반 Chrome 또는 종료 근거가 부족한 프로필로 확인되어 보호했습니다."
        case .signalFailed:
            return "자동화 브라우저에 정상 종료 요청을 전달하지 못했습니다. 강제 종료하지 않았습니다."
        case .stillRunning:
            return "정상 종료를 요청했지만 5초 안에 끝나지 않았습니다. 강제 종료하지 않았으니 소유 작업을 확인해 주세요."
        }
    }
}
