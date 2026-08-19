import Foundation
import MothballCore

/// Connects scree's already-discovered workspace paths to MothballCore's
/// own read-only repo scanner and safety classifier -- the "real consumer"
/// deferred when MothballCore was first linked into Modore's build graph.
/// Read-only: MothballCore's scanner only runs `git log`/`status`/`config`/
/// `rev-parse`/`rev-list` (no `fetch` -- GitInspector defaults that off),
/// and this connection stops at display. Archiving (compress + trash the
/// original) is Mothball's own standalone app; wiring that destructive
/// action into Modore is deliberately a separate, later step, the same
/// display-first precedent scree's own first UI integration set.
enum MothballService {
    /// Every lineage path scree already confirmed both exists and is a git
    /// repo becomes one scan root. Pure and independently testable. `limit`
    /// keeps a pathological session history (thousands of distinct
    /// workspaces) from turning one page load into an unbounded git-process
    /// fan-out.
    static func candidateRoots(from lineagePaths: [ScreeLineagePath], limit: Int = 300) -> [URL] {
        lineagePaths
            .filter { $0.exists && $0.hasGit }
            .prefix(limit)
            .map { URL(fileURLWithPath: $0.path) }
    }

    /// Pure and independently testable: which scanned repos are worth
    /// showing as archive candidates, and in what order. `.unsafe` repos
    /// (actively used, or unrecoverable if archived -- no remote, or dirty/
    /// unpushed work) are never shown here; this list exists to surface
    /// what is worth considering, not a dump of every repo scree ever saw.
    static func rankCandidates(
        repos: [RepoInfo],
        classifier: SafetyClassifier = SafetyClassifier(),
        now: Date = Date()
    ) -> [ArchiveCandidate] {
        repos
            .compactMap { repo -> ArchiveCandidate? in
                let verdict = classifier.classify(repo, now: now)
                guard verdict.tier != .unsafe else { return nil }
                let dormancyDays = max(0, Int(now.timeIntervalSince(repo.lastActivity) / 86_400))
                return ArchiveCandidate(repo: repo, verdict: verdict, dormancyDays: dormancyDays)
            }
            .sorted { $0.repo.sizeBytes > $1.repo.sizeBytes }
    }

    /// `scanReport`, not `scan`: the latter drops the inspection failures,
    /// and MothballCore's own API comment warns why that matters -- a repo
    /// found but not inspectable (corrupt .git, permission denied, git
    /// timeout) would otherwise be indistinguishable from no repo at all, and
    /// the page would state "nothing worth archiving" when the truth is that
    /// it could not look.
    static func scanCandidates(
        lineagePaths: [ScreeLineagePath]
    ) async -> (candidates: [ArchiveCandidate], failureCount: Int) {
        let roots = candidateRoots(from: lineagePaths)
        guard !roots.isEmpty else { return ([], 0) }
        let report = await RepoScanner().scanReport(roots: roots)
        return (rankCandidates(repos: report.repos), report.failures.count)
    }

    /// Asks the binder which AI sessions belong to each candidate.
    ///
    /// Run after ranking rather than inside it: `rankCandidates` is a pure
    /// function over git state and stays that way, and binding is a
    /// subprocess per repo. Candidates that were never bound keep their
    /// `.notAssessed` default, which is the honest answer and the one the
    /// gate refuses to archive from — a binder that fails must not leave a
    /// repo looking session-free.
    static func withContinuity(
        _ candidates: [ArchiveCandidate],
        projectRoot: URL
    ) async -> [ArchiveCandidate] {
        var out: [ArchiveCandidate] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            var updated = candidate
            let outcome = await ScreeService.bind(
                projectRoot: projectRoot,
                workspace: candidate.repo.path,
                repoURL: candidate.repo.git.originURL
            )
            updated.continuity = outcome.assessment
            updated.continuityDiagnostic = outcome.diagnostic
            out.append(updated)
        }
        return out
    }
}

extension ScanModel {
    func refreshArchiveCandidates() {
        guard !archiveLoading else { return }
        guard let report = screeReport else {
            archiveError = "먼저 AI 세션 감사를 실행하세요."
            return
        }
        archiveLoading = true
        archiveError = nil
        let paths = report.lineagePaths
        Task {
            defer { archiveLoading = false }
            let outcome = await MothballService.scanCandidates(lineagePaths: paths)
            // Show the git judgment first, then fill in session bindings:
            // binding spawns one subprocess per repo, and a long wait for
            // it would otherwise hold back a list that is already useful.
            // Until it lands every row reads "AI 세션 확인 안 됨", which is
            // true rather than reassuring.
            archiveCandidates = outcome.candidates
            archiveInspectionFailures = outcome.failureCount
            archiveCandidates = await MothballService.withContinuity(
                outcome.candidates, projectRoot: projectRoot
            )
        }
    }
}
