import Foundation

enum ReportArtifactState: Equatable {
    case unknown
    case generated
    case failed
}

struct ReportState: Equatable {
    let normal: ReportArtifactState
    let share: ReportArtifactState
    let attemptedAt: Date?

    static let unknown = ReportState(
        normal: .unknown,
        share: .unknown,
        attemptedAt: nil
    )

    init(
        normal: ReportArtifactState,
        share: ReportArtifactState,
        attemptedAt: Date?
    ) {
        self.normal = normal
        self.share = share
        self.attemptedAt = attemptedAt
    }

    init(runResult: ScanRunResult, attemptedAt: Date) {
        normal = Self.artifactState(from: runResult.normalReport)
        share = Self.artifactState(from: runResult.shareReport)
        self.attemptedAt = attemptedAt
    }

    var hasFailure: Bool { normal == .failed || share == .failed }

    var failureText: String? {
        switch (normal, share) {
        case (.failed, .failed):
            return "정밀 검사는 완료됐지만 일반·공유용 리포트를 생성하지 못했습니다."
        case (.failed, _):
            return "정밀 검사는 완료됐지만 일반 리포트를 생성하지 못했습니다."
        case (_, .failed):
            return "정밀 검사는 완료됐지만 공유용 리포트를 생성하지 못했습니다."
        default:
            return nil
        }
    }

    private static func artifactState(from state: PipelineStageState) -> ReportArtifactState {
        switch state {
        case .notAttempted: return .unknown
        case .succeeded: return .generated
        case .failed: return .failed
        }
    }
}
