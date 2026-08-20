import Foundation

/// Turns found sessions into sealed ones, as an explicit step.
///
/// Not folded into `ArchiveOrchestrator.archive`. Sealing copies every
/// bound transcript and its subagent tree -- measured on this machine,
/// 387 MB for one repo -- and a call that quietly does that inside what
/// reads like a compress-and-trash is a surprise the caller cannot
/// budget for. It is also the step whose failure means "nothing was
/// preserved", which deserves to be distinguishable from a tar that
/// failed later.
///
/// The gate still decides. This only moves an assessment from "found" to
/// "kept"; whether that is enough remains a question about coverage.
public enum ContinuityPreparation {

    public struct Prepared: Sendable {
        public let assessment: ContinuityAssessment
        /// Staging tree to remove once the archive is written, or `nil`
        /// when nothing was sealed. The caller owns it: it has to outlive
        /// the compression that reads from it.
        public let stagingRoot: URL?
    }

    /// - Parameter stagingParent: where the copies are made. Should sit
    ///   on the same volume as the archive directory so the bytes are not
    ///   copied twice.
    public static func seal(
        _ assessment: ContinuityAssessment,
        stagingParent: URL,
        sealer: ContinuitySealer = ContinuitySealer()
    ) throws -> Prepared {
        guard case .bindings(let bindings, let coverage) = assessment else {
            // Everything else is already as sealed as it will get:
            // `.sealed` has its bytes, and the three states with nothing
            // to preserve have nothing to copy.
            return Prepared(assessment: assessment, stagingRoot: nil)
        }
        guard !bindings.isEmpty else {
            // A binder that found nothing should have said
            // `assessedNoSessions`. Sealing an empty list into a
            // `.sealed` would launder that caller bug into a pass, so the
            // degenerate value travels on unchanged and the gate refuses.
            return Prepared(assessment: assessment, stagingRoot: nil)
        }
        let bundle = try sealer.seal(bindings: bindings, stagingParent: stagingParent)
        // Coverage travels through sealing untouched. Copying bytes says
        // nothing about the stores nobody read.
        return Prepared(
            assessment: .sealed(bundle, coverage: coverage),
            stagingRoot: bundle.stagingRoot
        )
    }

    /// Whether a repo still looks the way it did when it was assessed.
    ///
    /// Compares the facts the safety judgement rested on, not everything
    /// git knows: a new untracked scratch file is not a reason to refuse,
    /// a moved HEAD or newly-dirty tree is. Kept here rather than in the
    /// caller so both apps refuse on the same grounds.
    public static func gitDrift(from before: GitMetadata, to after: GitMetadata) -> String? {
        if before.headSHA != after.headSHA {
            return "커밋이 변경됐습니다 (\(before.headSHA ?? "없음") → \(after.headSHA ?? "없음"))"
        }
        if before.isDirty != after.isDirty {
            return after.isDirty ? "커밋되지 않은 변경이 새로 생겼습니다" : "작업 트리 상태가 바뀌었습니다"
        }
        if before.aheadOfOrigin != after.aheadOfOrigin {
            return "푸시되지 않은 커밋 수가 바뀌었습니다"
        }
        if before.currentBranch != after.currentBranch {
            return "브랜치가 바뀌었습니다"
        }
        return nil
    }

    /// Uncompressed bytes `seal` would copy, so a caller can show the
    /// cost before agreeing to it rather than after.
    public static func estimatedBytes(_ assessment: ContinuityAssessment) -> Int64 {
        switch assessment {
        case .bindings(let bindings, _):
            return bindings.reduce(0) { $0 + $1.sizeBytes }
        case .sealed(let bundle, _):
            return bundle.totalBytes
        case .notAssessed, .assessedNoSessions, .overriddenByUser:
            return 0
        }
    }
}
