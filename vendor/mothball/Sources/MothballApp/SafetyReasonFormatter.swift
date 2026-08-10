import Foundation
import MothballCore

struct SafetyReasonFormatter {
    let thresholds: SafetyClassifier.Thresholds

    init(thresholds: SafetyClassifier.Thresholds = .default) {
        self.thresholds = thresholds
    }

    func string(for reason: SafetyReason) -> String {
        switch reason {
        case .recentActivity(let days):
            return "마지막 활동 \(days)일 전 (\(thresholds.recentActivityDays)일 미만)"
        case .dirtyWorkingTree:
            return "커밋되지 않은 변경 사항 있음"
        case .unpushedCommits(let count):
            return "origin에 push되지 않은 커밋 \(count)개"
        case .noRemoteConfigured:
            return "origin remote 설정 없음 (복원 불가)"
        case .noUpstreamConfigured:
            return "현재 브랜치에 upstream 추적 없음"
        case .noCommitsYet:
            return "커밋이 하나도 없는 빈 저장소"
        case .dormant(let days):
            return "휴면 상태 (\(days)일 전 마지막 활동)"
        case .fullyPushed:
            return "origin에 모두 push됨"
        }
    }

    func string(for verdict: SafetyVerdict) -> String {
        verdict.reasons.map { string(for: $0) }.joined(separator: "\n")
    }
}
