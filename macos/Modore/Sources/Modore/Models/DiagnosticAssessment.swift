import Foundation

/// Analysis of recorded intervals, never an input-to-display latency estimate.
/// Boundary-crossing samples are excluded rather than attributed to an action.
struct DiagnosticWindow: Sendable {
    let frames: [DiagnosticFrame]
    let renderer: Bool
    let span: Double

    init(frames: [DiagnosticFrame], start: Double, end: Double, renderer: Bool) {
        self.frames = frames.filter {
            $0.interval > 0 && $0.seconds - $0.interval >= start - 0.000001 && $0.seconds <= end
        }
        self.renderer = renderer
        span = end - start
    }
    func value(_ frame: DiagnosticFrame) -> Double? { renderer ? frame.rendererCPU : frame.targetCPU }
    var measured: [DiagnosticFrame] { frames.filter { value($0) != nil } }
    var mean: Double? {
        let rows = measured
        let duration = rows.reduce(0) { $0 + $1.interval }
        return duration > 0 ? rows.reduce(0) { $0 + value($1)! * $1.interval } / duration : nil
    }
    var peak: DiagnosticFrame? { measured.max { value($0)! < value($1)! } }
    var complete: Bool {
        measured.reduce(0) { $0 + $1.interval } >= span * 0.75 &&
            !frames.contains { $0.unavailable > 0 || value($0) == nil }
    }
}

struct DiagnosticActionAssessment: Sendable {
    let event: DiagnosticEvent
    let before: DiagnosticWindow
    let after: DiagnosticWindow
    let stacksOverlap: Bool
    let otherActionOverlaps: Bool
    var highCPU: Bool { after.peak.flatMap(after.value).map { $0 >= 150 } ?? false }
    var rose: Bool {
        guard before.complete, after.complete, !stacksOverlap, !otherActionOverlaps,
              let baseline = before.mean, let peak = after.peak.flatMap(after.value) else { return false }
        return peak >= max(150, baseline * 2, baseline + 75)
    }
    var description: String {
        func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "미확인" }
        let metric = after.renderer ? "Renderer" : "앱·작업 합산"
        var text = "\(event.detail) (+\(number(event.seconds))초): \(metric) CPU, 표식 전 평균 \(number(before.mean))% → 표식 후 평균 \(number(after.mean))%"
        if let peak = after.peak {
            text += ", 최고 \(number(after.value(peak)))% (표식 후 \(number(peak.seconds - event.seconds))초 표본)."
        } else { text += "." }
        if rose { text += " 표식 직후 CPU 급증이 관측됐습니다." }
        else if highCPU { text += " 표식 직후 높은 CPU 사용이 관측됐습니다." }
        else if after.complete { text += " 이 구간에서 150% 이상 CPU 부하는 관측되지 않았습니다. 화면 지연이 없었다는 뜻은 아닙니다." }
        else { text += " 표식 후 구간의 CPU 관측이 부족합니다." }
        if !before.complete { text += " 표식 전 자료가 불완전해 증가율은 판정하지 않습니다." }
        if !after.complete { text += " 표식 후 자료에 누락 또는 짧은 관찰 구간이 있습니다." }
        if stacksOverlap { text += " 스택 수집과 겹친 구간입니다." }
        if otherActionOverlaps { text += " 다른 동작 표식과 겹쳐 개별 동작에 귀속하지 않습니다." }
        return text
    }
}

extension DiagnosticResult {
    var actionAssessments: [DiagnosticActionAssessment] {
        let actions = events.filter { $0.kind == "manual" || $0.kind == "auto-start" }
        return actions.map { event in
            // Legacy recordings have aggregate CPU only. Do not invent renderer attribution.
            let renderer = frames.contains { $0.rendererCPU != nil && abs($0.seconds - event.seconds) <= 3 }
            return DiagnosticActionAssessment(event: event,
                before: DiagnosticWindow(frames: frames, start: event.seconds - 3, end: event.seconds, renderer: renderer),
                after: DiagnosticWindow(frames: frames, start: event.seconds, end: event.seconds + 3, renderer: renderer),
                stacksOverlap: events.contains { $0.kind == "stack-start" && $0.seconds <= event.seconds + 3 && $0.seconds + 6 >= event.seconds - 3 },
                otherActionOverlaps: actions.contains { $0.seconds != event.seconds && abs($0.seconds - event.seconds) < 3 })
        }
    }
    var diagnosticHeadline: String {
        headline(actions: actionAssessments)
    }
    func headline(actions: [DiagnosticActionAssessment]) -> String {
        if actions.contains(where: { $0.rose }) { return "동작 표식 직후 CPU 급증 관측" }
        if actions.contains(where: { $0.highCPU }) { return "동작 표식 직후 높은 CPU 사용 관측" }
        if let peakCPU, peakCPU >= 150 { return "검사 중 앱·작업 합산 고부하 관측" }
        if frames.contains(where: { $0.targetCPU != nil }) { return "CPU 고부하 미관측 · 화면 지연 여부와 별개" }
        return "CPU 관측 자료 부족"
    }
    var assessmentReport: String {
        var text = "## 분석 결과\n\n\(diagnosticHeadline)\n\n"
        for action in actionAssessments { text += "- \(action.description)\n" }
        if actionAssessments.isEmpty { text += "동작 표식이 없어 개별 조작 전후 비교는 없습니다.\n" }
        text += "\n표식 전후 각 3초에서 경계를 넘지 않는 CPU 표본을 비교합니다. 150%는 원인 추적용 기준이며 정상/비정상 판정 기준은 아닙니다. 표식과 부하의 시간적 관계를 보여주며, 입력 지연 시간이나 인과관계를 증명하지 않습니다.\n"
        if !frames.contains(where: { $0.topProcesses != nil }) {
            text += "이 기록은 프로세스별 CPU를 저장하지 않아 Renderer와 작업 프로세스를 구분할 수 없습니다.\n"
        }
        text += "이 검사에는 시스템 전체 메모리 압력·디스크 대기·화면 프레임 측정이 없어 로컬 시스템과 앱의 원인을 단독 확정할 수 없습니다.\n"
        return text
    }
}

/// Computed once when loading/saving a result, not on each live UI sample.
struct DiagnosticPresentation: Sendable {
    let headline: String
    let actions: [String]
    init(_ result: DiagnosticResult) {
        let assessments = result.actionAssessments
        headline = result.headline(actions: assessments)
        actions = assessments.prefix(6).map(\.description)
    }
}

/// Bounded evidence capture only. A high CPU value does not imply an app defect.
enum DiagnosticSpikePolicy {
    static func target(frame: DiagnosticFrame, count: Int, lastAttempt: Double, sampling: Bool) -> Int32? {
        guard count < 2, !sampling, frame.seconds - lastAttempt >= 30, frame.thermal < 2 else { return nil }
        let processes = frame.topProcesses ?? []
        if let renderer = processes.filter({ $0.name.contains("Renderer") }).max(by: { $0.cpu < $1.cpu }), renderer.cpu >= 150 {
            return renderer.pid
        }
        guard (frame.targetCPU ?? 0) >= 200 else { return nil }
        return processes.max(by: { $0.cpu < $1.cpu })?.pid
    }
}
