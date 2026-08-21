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
        assessRepos(repos: repos, classifier: classifier, now: now)
            .filter(\.isRetirementEligible)
    }

    /// Every repo that was scanned, judged, and kept -- including the ones
    /// that must never be archived.
    ///
    /// `rankCandidates` answers "what could be retired", and dropping
    /// `.unsafe` repos is right for that question. It is exactly wrong as
    /// a source of a project's git state: dirty trees and unpushed
    /// commits are what makes a repo `.unsafe`, so the repos carrying the
    /// most important work were the ones that vanished, leaving the 작업
    /// screen to mark them clean and put a warning on the dormant repos
    /// that had nothing wrong with them.
    static func assessRepos(
        repos: [RepoInfo],
        classifier: SafetyClassifier = SafetyClassifier(),
        now: Date = Date()
    ) -> [ArchiveCandidate] {
        repos
            .map { repo in
                ArchiveCandidate(
                    repo: repo,
                    verdict: classifier.classify(repo, now: now),
                    dormancyDays: max(0, Int(now.timeIntervalSince(repo.lastActivity) / 86_400))
                )
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
        // Every assessment, not only the archivable ones. Which of them
        // may be retired is a question `isRetirementEligible` answers per
        // repo; the screen also has to say what state the others are in.
        return (assessRepos(repos: report.repos), report.failures.count)
    }

    /// Reads titles for the handful of sessions one row will show, when
    /// that row is opened.
    ///
    /// Never during a scan. scree's contract is that an audit reads
    /// metadata and retains no conversation content, with `preserve` as
    /// the one deliberate exception a person asks for by name. Titling
    /// every candidate on refresh would quietly make every scan a
    /// content read, which is a change to the security model rather than
    /// a feature -- so it happens on expand, for one repo, bounded to
    /// what is displayed.
    static func titles(
        for candidate: ArchiveCandidate,
        projectRoot: URL
    ) async -> [SessionPresentation] {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return []
        }
        var titles: [SessionPresentation] = []
        for binding in candidate.topBindings() {
            if let presentation = await ScreeService.title(
                execution: execution, binding: binding
            ) {
                titles.append(presentation)
            }
        }
        return titles.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
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
        guard !candidates.isEmpty else { return candidates }
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            // Every candidate keeps its `.notAssessed` default -- the
            // honest answer, and the one the gate refuses to archive
            // from. A binder that could not run must not leave a repo
            // looking session-free.
            return candidates
        }

        // One pass for the whole screen. A shallow scan never establishes
        // completeness, so every candidate needs a deep look, and asking
        // one repo at a time re-reads the entire session store per repo:
        // measured here, 12.8 minutes across 53 candidates one by one
        // against 2.8 minutes in a single pass, both reaching complete
        // coverage for all 53.
        let outcomes = await ScreeService.bindAll(
            execution: execution,
            targets: candidates.map { ($0.repo.path, $0.repo.git.originURL) }
        )

        var out: [ArchiveCandidate] = []
        out.reserveCapacity(candidates.count)
        for candidate in candidates {
            var updated = candidate
            if let outcome = outcomes[candidate.repo.path.path] {
                updated.continuity = outcome.assessment
                updated.continuityDiagnostic = outcome.diagnostic
            }
            out.append(updated)
        }
        // Re-sort once bindings are known. `rankCandidates` orders by repo
        // size because that is all it has; what actually decides this page
        // is how much conversation a delete would strand, and the two
        // orders disagree -- the largest repo here has four bound sessions
        // and a smaller one has a hundred and twenty.
        return out.sorted {
            if $0.boundSessions.count != $1.boundSessions.count {
                return $0.boundSessions.count > $1.boundSessions.count
            }
            return $0.repo.sizeBytes > $1.repo.sizeBytes
        }
    }
}

extension ScanModel {
    /// Loads one session's conversation when a person opens it.
    ///
    /// Keyed by the bytes, not the path. A live agent appends to its
    /// transcript while this screen is open, so a path-keyed entry is
    /// stale the moment the session it describes continues -- and the
    /// staleness is invisible, because the path still resolves. The
    /// title cache already answers this with `PresentationCacheKey`
    /// (file identity + mtime + size); the same question gets the same
    /// key rather than a second, weaker one.
    ///
    /// `retry` exists because a failure is cached like anything else:
    /// without it, the one thing a person does after seeing an error is
    /// the one thing that cannot re-run.
    func loadConversation(for binding: SessionBinding, retry: Bool = false) {
        let key = conversationKey(for: binding)
        if retry {
            conversationLoads[key] = nil
        } else if conversationLoads[key] != nil {
            return
        }
        conversationLoads[key] = .loading
        let root = projectRoot
        Task {
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                conversationLoads[key] = .failed("서명된 실행 런타임을 확인하지 못했습니다.")
                return
            }
            switch await ScreeService.inspect(execution: execution, binding: binding) {
            case .success(let conversation):
                conversationLoads[key] = .loaded(conversation)
            case .failure(let error):
                conversationLoads[key] = .failed(error.message)
            }
        }
    }

    /// Loads the session browser's index. Metadata only -- no transcript
    /// body is opened to build it.
    func refreshSessionIndex() {
        guard !sessionIndexLoading else { return }
        sessionIndexLoading = true
        sessionIndexError = nil
        let root = projectRoot
        Task {
            defer { sessionIndexLoading = false }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                sessionIndexError = "서명된 실행 런타임을 확인하지 못했습니다."
                return
            }
            switch await ScreeService.sessions(execution: execution) {
            case .success(let index):
                sessionIndex = index
            case .failure(let error):
                sessionIndexError = error.message
            }
        }
    }

    /// Everything the Work screen shows, assembled from the three
    /// scanners that used to own a screen each.
    var workProjects: [WorkProject] {
        WorkProjectBuilder.build(
            sessions: sessionIndex?.sessions ?? [],
            worktrees: screeReport?.worktreeItems ?? [],
            assessments: repoAssessments ?? [],
            // Every git path the audit saw, so project identity does not
            // depend on which repos survived the archive classifier or the
            // scanner's own root limit.
            gitRoots: (screeReport?.lineagePaths ?? [])
                .filter(\.hasGit).map(\.path)
        )
    }

    /// Loads what the Work screen needs the moment someone opens it.
    ///
    /// Entering the screen *is* the explicit intent -- the privacy line
    /// this project holds is metadata-only *judgment*, not a rule that a
    /// listing must be asked for twice. Nothing here reads a transcript
    /// body; titles are fetched separately, for rows that are actually on
    /// screen, and are never an input to a verdict.
    func prepareWorkScreen() {
        if sessionIndex == nil && !sessionIndexLoading && sessionIndexError == nil {
            refreshSessionIndex()
        }
        if screeReport == nil && !screeLoading && screeError == nil {
            refreshScreeReport()
        } else if screeReport != nil && repoAssessments == nil
                    && !archiveLoading && archiveError == nil {
            // The git judgment needs the workspace list the audit
            // produces, which is why the old page could not start without
            // it -- the shape of a step in a workflow, not a peer screen.
            refreshArchiveCandidates()
        }
    }

    /// Fetches titles for the rows a screen is about to show, in one pass.
    ///
    /// Bounded to what is visible on purpose. Titling every session on the
    /// machine would be a content read of 7,000 transcripts to label rows
    /// nobody scrolled to.
    func loadSessionTitles(for sources: [String]) {
        let wanted = sources.filter { sessionTitles[$0] == nil && !titleRequests.contains($0) }
        guard !wanted.isEmpty else { return }
        titleRequests.formUnion(wanted)
        let root = projectRoot
        Task {
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                titleRequests.subtract(wanted)
                return
            }
            let fetched = await ScreeService.titles(execution: execution, sources: wanted)
            guard !fetched.isEmpty else {
                // Let a later pass try again rather than leaving these rows
                // permanently unlabelled.
                titleRequests.subtract(wanted)
                return
            }
            sessionTitles.merge(fetched) { _, new in new }
        }
    }

    /// Same fetch as `loadConversation(for:)`, for a browser row that has
    /// a transcript but no binding to any repo.
    func loadConversation(for entry: SessionIndexEntry, retry: Bool = false) {
        let key = Self.conversationKey(
            provider: entry.provider, sessionID: entry.source, source: entry.sourceURL
        )
        if retry {
            conversationLoads[key] = nil
        } else if conversationLoads[key] != nil {
            return
        }
        conversationLoads[key] = .loading
        let root = projectRoot
        let source = entry.sourceURL
        Task {
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                conversationLoads[key] = .failed("서명된 실행 런타임을 확인하지 못했습니다.")
                return
            }
            switch await ScreeService.inspect(execution: execution, source: source) {
            case .success(let conversation):
                conversationLoads[key] = .loaded(conversation)
            case .failure(let error):
                conversationLoads[key] = .failed(error.message)
            }
        }
    }

    func conversationState(for entry: SessionIndexEntry) -> ConversationLoadState? {
        conversationLoads[Self.conversationKey(
            provider: entry.provider, sessionID: entry.source, source: entry.sourceURL
        )]
    }

    /// The cache identity for one binding's conversation.
    ///
    /// Falls back to the path only when the file cannot be stat'd at all
    /// -- which is itself a state `inspect` will report on, so the fetch
    /// still has to run rather than being skipped here.
    nonisolated static func conversationKey(
        provider: SessionProvider, sessionID: String, source: URL
    ) -> String {
        guard let key = PresentationCacheKey(
            provider: provider, sessionID: sessionID, source: source
        ) else {
            return "unstattable:\(provider.rawValue)/\(sessionID)/\(source.path)"
        }
        return "\(key.provider.rawValue)/\(key.sessionID)/\(key.fileIdentity)"
            + "/\(key.modifiedAt.timeIntervalSince1970)/\(key.sizeBytes)"
    }

    func conversationKey(for binding: SessionBinding) -> String {
        Self.conversationKey(
            provider: binding.provider, sessionID: binding.sessionID, source: binding.source
        )
    }

    /// What the row should render for this binding right now.
    func conversationState(for binding: SessionBinding) -> ConversationLoadState? {
        conversationLoads[conversationKey(for: binding)]
    }

    /// Fills in one row's titles when it is opened. Idempotent: a row
    /// already titled is not read again.
    func loadTitles(for candidate: ArchiveCandidate) {
        guard let index = repoAssessments?.firstIndex(where: { $0.id == candidate.id }),
              repoAssessments?[index].presentations.isEmpty == true,
              !candidate.boundSessions.isEmpty else { return }
        let root = projectRoot
        let target = candidate
        Task {
            let titles = await MothballService.titles(for: target, projectRoot: root)
            guard let current = repoAssessments?.firstIndex(where: { $0.id == target.id })
            else { return }
            repoAssessments?[current].presentations = titles
        }
    }

    func refreshArchiveCandidates() {
        guard !archiveLoading else { return }
        guard let report = screeReport else {
            archiveError = "작업 감사를 먼저 실행해야 저장소를 판정할 수 있습니다."
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
            repoAssessments = outcome.candidates
            archiveInspectionFailures = outcome.failureCount
            repoAssessments = await MothballService.withContinuity(
                outcome.candidates, projectRoot: projectRoot
            )
        }
    }
}
