import Foundation

struct DiagnosticTarget: Codable, Equatable, Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let birth: UInt64
    let name: String
    let bundleID: String
    let version: String
}

struct DiagnosticProcess: Codable, Sendable {
    let pid: Int32
    let name: String
    let cpu: Double
}

struct DiagnosticFrame: Codable, Sendable {
    let seconds: Double
    let interval: Double
    let targetCPU: Double?
    let observerCPU: Double?
    let samplerCPU: Double?
    let residentBytes: UInt64
    let available: Int
    let unavailable: Int
    let collectionMilliseconds: Double
    let thermal: Int
    var rendererCPU: Double?
    var topProcesses: [DiagnosticProcess]?
}

struct DiagnosticEvent: Codable, Sendable {
    let seconds: Double
    let kind: String
    let detail: String
    var stackID: Int?
    var processID: Int32?
    var samplerPID: Int32?
    var stackFile: String?
    var displayDetail: String {
        guard kind == "manual" || kind == "auto-start" else { return detail }
        return ["first-input": "첫 입력", "continued-input": "계속 입력", "sidebar": "목록 이동",
                "sidebar-hover": "목록으로 포인터 이동", "attachment": "사진 첨부", "stutter": "끊김 발생"][detail] ?? detail
    }
}

struct DiagnosticResult: Codable, Identifiable, Sendable {
    let id: UUID
    let target: DiagnosticTarget
    let condition: String
    let started: Date
    let frames: [DiagnosticFrame]
    let events: [DiagnosticEvent]
    let finishReason: String
    let timebaseNumer: UInt32
    let timebaseDenom: UInt32
    let schemaVersion: Int

    var meanCPU: Double? {
        let valid = frames.filter { $0.targetCPU != nil && $0.interval > 0 }
        let duration = valid.reduce(0) { $0 + $1.interval }
        return duration > 0 ? valid.reduce(0) { $0 + $1.targetCPU! * $1.interval } / duration : nil
    }
    var meanRendererCPU: Double? {
        let valid = frames.filter { $0.rendererCPU != nil && $0.interval > 0 }
        let duration = valid.reduce(0) { $0 + $1.interval }
        return duration > 0 ? valid.reduce(0) { $0 + $1.rendererCPU! * $1.interval } / duration : nil
    }
    var peakCPU: Double? { frames.compactMap(\.targetCPU).max() }
    var peakRSS: UInt64 { frames.map(\.residentBytes).max() ?? 0 }
    var incomplete: Bool { frames.allSatisfy { $0.targetCPU == nil } || frames.contains { $0.unavailable > 0 || ($0.interval > 0 && $0.targetCPU == nil) } }
    var coverageDescription: String {
        let measured = frames.filter { $0.interval > 0 && $0.targetCPU != nil }.reduce(0) { $0 + $1.interval }
        let missing = frames.filter { $0.interval > 0 && ($0.unavailable > 0 || $0.targetCPU == nil) }.count
        return String(format: "CPU 관측 %.1f초 · 누락 표본 %d개%@", measured, missing,
                      incomplete ? " · 부분 합산값은 실제 부하보다 낮을 수 있습니다." : "")
    }
    var replayCompleted: Bool {
        let starts = events.filter { $0.kind == "auto-start" && $0.detail == "first-input" }.count
        return starts > 0 && events.filter { $0.kind == "auto-finished" }.count == starts
    }
    var hasStacks: Bool { events.contains { $0.kind == "stack-start" } }
    var actionSignature: [String] { events.filter { $0.kind == "auto-start" }.map(\.detail) }

    func comparisonWarning(_ other: Self) -> String? {
        if target.bundleID != other.target.bundleID { return "대상 앱이 다릅니다." }
        if actionSignature.isEmpty || actionSignature != other.actionSignature { return "같은 자동 동작의 반복이 아닙니다. 참고 비교만 가능합니다." }
        if events.contains(where: { $0.kind == "auto-stopped" }) || other.events.contains(where: { $0.kind == "auto-stopped" }) {
            return "중단된 자동 재현이 포함됐습니다. 참고 비교만 가능합니다."
        }
        if !replayCompleted || !other.replayCompleted { return "자동 재현의 입력 제거·종료 확인이 부족합니다. 참고 비교만 가능합니다." }
        if incomplete || other.incomplete { return "누락된 관찰값이 있습니다. 참고 비교만 가능합니다." }
        if hasStacks != other.hasStacks { return "스택 수집 조건이 다릅니다. 참고 비교만 가능합니다." }
        return nil
    }

    var report: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "미확인" }
        // Fixed metadata only: no condition text, paths, input content or process arguments in share report.
        var text = "# Modore 앱 재현 검사\n\n앱: \(target.name) · \(target.bundleID) · \(target.version)\n"
        text += "시작: \(ISO8601DateFormatter().string(from: started))\n결과: \(finishReason)\n"
        text += "\nCPU 평균 \(number(meanCPU))% · 최대 \(number(peakCPU))% · 표본 \(frames.count)개\n"
        if let meanRendererCPU {
            text += "Renderer CPU 평균 \(number(meanRendererCPU))% · 최대 \(number(frames.compactMap(\.rendererCPU).max()))%\n"
        }
        if let peak = frames.filter({ $0.targetCPU != nil }).max(by: { $0.targetCPU! < $1.targetCPU! }), let processes = peak.topProcesses {
            text += "\n합산 최고점(+\(number(peak.seconds))초)의 상위 프로세스:\n"
            for process in processes { text += "- \(process.name) · PID \(process.pid): \(number(process.cpu))%\n" }
        }
        text += "\(coverageDescription)\n"
        text += "관측 누락: \(incomplete ? "있음" : "없음") · Mach timebase \(timebaseNumer)/\(timebaseDenom)\n"
        text += "\n" + assessmentReport
        text += "\n| 경과 초 | 종류 | 기록 |\n|---:|---|---|\n"
        for event in events {
            let stack = event.stackFile.map { " · 파일 " + $0 } ?? ""
            text += "| \(number(event.seconds)) | \(event.kind) | \(event.displayDetail)\(stack) |\n"
        }
        text += "\n100%는 코어 하나입니다. 합산 CPU에는 앱의 작업·도구 프로세스도 포함되며 UI 부하만을 뜻하지 않습니다. Renderer는 프로세스 이름으로 구분하며 지원하지 않는 앱에서는 미확인입니다. CPU는 동일 시점의 대상 앱과 자식 프로세스를 합산하고 시간 가중 평균을 냈습니다. RSS는 공유 메모리가 중복될 수 있습니다. 첫 표본·접근 실패·수집 중단 구간을 0으로 처리하지 않습니다.\n"
        text += "입력 처리 시간과 입력→프레임 지연은 수집하지 않습니다. 자동 동작 기록은 요청 및 접근성 상태 확인이며 화면 표시 완료나 입력 지연 측정이 아닙니다. 수동 표식은 사용자가 누른 시각이며 실제 조작 시각의 자동 판별이 아닙니다. CPU 감소만으로 버벅임 해결을 판정하지 않습니다. 스택 수집은 추가 부하를 만듭니다.\n"
        text += "원본 스택은 native-private에 있으며 경로 등 비공개 정보가 포함될 수 있습니다. report.md만 공유용으로 사용하세요.\n"
        return text
    }
}

enum DiagnosticBudget {
    static let duration: Double = 300
    static let frames = 600
    static let events = 300
    static let processes = 64
    static let stacks = 3
    static func delay(collectionSeconds: Double, thermal: Int) -> Double {
        max(thermal >= 2 ? 2 : 0.5, min(5, collectionSeconds * 49))
    }
}
