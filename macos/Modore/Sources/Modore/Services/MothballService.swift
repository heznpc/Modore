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
        scanScope(from: lineagePaths, limit: limit).roots
    }

    /// The roots a scan will cover, and the ones the cap leaves out.
    ///
    /// The cap keeps a pathological session history from turning one page
    /// load into an unbounded git-process fan-out, and it has to stay.
    /// What cannot stay is dropping the excess silently: the 작업 screen
    /// is now the authority on every project's git state, so a repo that
    /// was never looked at drew the same clean row as a repo that was
    /// looked at and found clean. The cap is not currently reached on the
    /// reference machine, but if it is reached the omitted repos must remain
    /// explicit rather than looking clean.
    static func scanScope(
        from lineagePaths: [ScreeLineagePath], limit: Int = 300
    ) -> (roots: [URL], notScanned: [String]) {
        let repos = lineagePaths
            .filter { $0.exists == true && $0.hasGit == true }
            .map(\.path)
        return (repos.prefix(limit).map { URL(fileURLWithPath: $0) },
                Array(repos.dropFirst(limit)))
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
    ) async -> RepoScanOutcome {
        let scope = scanScope(from: lineagePaths)
        guard !scope.roots.isEmpty else {
            return RepoScanOutcome(candidates: [], failures: [:], notScanned: scope.notScanned)
        }
        // scree already proved these exact lineage paths were repositories.
        // Inspect them directly: if one disappears meanwhile it becomes that
        // path's failure, never a fresh recursive walk outside the scan budget.
        let report = await RepoScanner().inspectKnownRepositories(scope.roots)
        // Every assessment, not only the archivable ones. Which of them
        // may be retired is a question `isRetirementEligible` answers per
        // repo; the screen also has to say what state the others are in.
        //
        // Failures travel by path, not as a count. A total tells the user
        // that something somewhere could not be read; only the path tells
        // them which row is not to be trusted.
        var failures: [String: String] = [:]
        for failure in report.failures {
            failures[failure.path.path] = failure.reason
        }
        return RepoScanOutcome(
            candidates: assessRepos(repos: report.repos),
            failures: failures,
            notScanned: scope.notScanned
        )
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
        let token = UUID()
        conversationLoadTokens[key] = token
        let root = projectRoot
        startTrackedApplicationTask(scope: .workScreen) { [weak self] in
            guard let self else { return }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                finishConversationLoad(
                    key: key,
                    token: token,
                    state: Task.isCancelled
                        ? nil
                        : .failed("서명된 실행 런타임을 확인하지 못했습니다.")
                )
                return
            }
            guard !Task.isCancelled else {
                finishConversationLoad(key: key, token: token, state: nil)
                return
            }
            let state: ConversationLoadState
            switch await ScreeService.inspect(execution: execution, binding: binding) {
            case .success(let conversation):
                state = .loaded(conversation)
            case .failure(let error):
                state = .failed(error.message)
            }
            finishConversationLoad(
                key: key,
                token: token,
                state: Task.isCancelled ? nil : state
            )
        }
    }

    /// Loads the session browser's index. Metadata only -- no transcript
    /// body is opened to build it.
    func refreshSessionIndex() {
        let root = projectRoot
        refreshSessionIndex {
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                return .failure(.init(message: "서명된 실행 런타임을 확인하지 못했습니다."))
            }
            guard !Task.isCancelled else {
                return .failure(.init(message: "세션 목록 읽기를 취소했습니다."))
            }
            return await ScreeService.sessions(execution: execution)
        }
    }

    /// Internal loader injection mirrors the audit loader: a retry supersedes
    /// the previous request, and only that newest generation may update UI.
    func refreshSessionIndex(
        using load: @escaping () async -> Result<SessionIndex, ScreeInspectionError>
    ) {
        guard !applicationTerminationStarted else { return }
        cancelAndRetainForDrain(sessionIndexTask)
        sessionIndexGeneration += 1
        let generation = sessionIndexGeneration
        sessionIndexNeedsRefresh = true
        sessionIndexLoading = true
        sessionIndexError = nil
        sessionIndexTask = Task {
            let outcome = await load()
            guard !Task.isCancelled, generation == sessionIndexGeneration else { return }
            switch outcome {
            case .success(let index):
                sessionIndex = index
            case .failure(let error):
                sessionIndexError = error.message
            }
            guard generation == sessionIndexGeneration else { return }
            sessionIndexNeedsRefresh = false
            sessionIndexLoading = false
            sessionIndexTask = nil
        }
    }

    /// Stops the loaders and explicit body search owned by the Work screen.
    /// Exports/backups have their own progress and safety contracts and are
    /// deliberately not cancelled by navigation.
    func cancelWorkScreenTasks() {
        retainPendingDrainTasks(cancelWorkScreenTaskHandles())
    }

    /// Captures handles before clearing model state so application termination
    /// can await the cancelled work rather than dropping the last owner of a
    /// subprocess cleanup sequence.
    func cancelWorkScreenTaskHandles() -> [Task<Void, Never>] {
        var tasks = [screeTask, sessionIndexTask, archiveTask, contentSearchTask]
            .compactMap { $0 }
        tasks.append(contentsOf: cancelTrackedApplicationTasks(in: .workScreen))

        screeGeneration += 1
        screeTask?.cancel()
        screeTask = nil
        screeLoading = false

        sessionIndexGeneration += 1
        sessionIndexTask?.cancel()
        sessionIndexTask = nil
        sessionIndexLoading = false

        let archiveWasInFlight = archiveTask != nil
        archiveGeneration += 1
        archiveTask?.cancel()
        archiveTask = nil
        archiveLoading = false
        if archiveWasInFlight { archiveBindingComplete = false }

        contentSearchGeneration += 1
        contentSearchTask?.cancel()
        contentSearchTask = nil
        contentSearchRunning = false

        // A cancelled row task must be retryable immediately when the Work
        // screen is opened again; do not wait for subprocess teardown to
        // unwind its `defer` before clearing transient cache markers.
        titleRequests.removeAll()
        sessionTitleRequestTokens.removeAll()
        candidateTitleRequestTokens.removeAll()
        conversationLoadTokens.removeAll()
        conversationLoads = conversationLoads.filter { $0.value != .loading }

        return tasks
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
                .filter { $0.hasGit == true }.map(\.path),
            scanFailures: repoScanFailures,
            notScanned: reposNotScanned
        )
    }

    /// Loads what the Work screen needs the moment someone opens it.
    ///
    /// Entering the screen *is* the explicit intent -- the privacy line
    /// this project holds is metadata-only *judgment*, not a rule that a
    /// listing must be asked for twice.
    ///
    /// This does reach transcript bodies, and the comment here used to
    /// deny it. The continuity binder runs `bind-all --deep`, which reads
    /// transcripts to find file-access evidence and emits only whether
    /// such evidence exists. That is inside the contract -- no body is
    /// retained and no verdict quotes one -- but a comment claiming the
    /// screen never reads a body was simply false, and a false comment
    /// about a privacy boundary is worse than none.
    func prepareWorkScreen() {
        guard !applicationTerminationStarted else { return }
        if sessionIndexNeedsRefresh && !sessionIndexLoading && sessionIndexError == nil {
            refreshSessionIndex()
        }
        if screeNeedsRefresh && !screeLoading && screeError == nil {
            refreshScreeReport()
        } else if screeReport != nil && !archiveBindingComplete
                    && !archiveLoading && archiveError == nil {
            // The git judgment needs the workspace list the audit
            // produces, which is why the old page could not start without
            // it -- the shape of a step in a workflow, not a peer screen.
            refreshArchiveCandidates()
        }
    }

    /// Searches conversation bodies. Explicit: a person typed a query and
    /// pressed return.
    ///
    /// Typing alone filters metadata, which is free. Reading 7,000
    /// transcripts is not, and doing it on every keystroke would turn a
    /// filter box into a disk scan.
    func runContentSearch() {
        guard !applicationTerminationStarted else { return }
        let query = sessionSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        // A search takes tens of seconds, which is long enough for the
        // person to type something else and press return again. Refusing
        // the second search while the first runs made the box feel
        // broken, and letting the first one land would have written a
        // stale answer under a different query. The newest request wins:
        // the previous one is cancelled, and any result that arrives from
        // a superseded generation is dropped.
        cancelAndRetainForDrain(contentSearchTask)
        contentSearchGeneration += 1
        let generation = contentSearchGeneration
        contentSearchRunning = true
        contentSearchError = nil
        let root = projectRoot
        contentSearchTask = Task {
            defer {
                if generation == contentSearchGeneration { contentSearchRunning = false }
            }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                if generation == contentSearchGeneration {
                    contentSearchError = "서명된 실행 런타임을 확인하지 못했습니다."
                }
                return
            }
            let outcome = await ScreeService.search(execution: execution, query: query)
            guard !Task.isCancelled, generation == contentSearchGeneration else { return }
            switch outcome {
            case .success(let result):
                contentSearch = result
            case .failure(let error):
                contentSearchError = error.message
            }
        }
    }

    /// Drops a finished search. The metadata filter keeps working.
    func clearContentSearch() {
        contentSearch = nil
        contentSearchError = nil
    }

    /// Opens the conversation a search result points at.
    ///
    /// From the match itself, never by looking the path back up in
    /// `sessionIndex`. The index is a snapshot from whenever the screen
    /// last loaded; the search walked the filesystem just now. A session
    /// created in between is findable and would have been unopenable --
    /// the click would have done nothing at all.
    func openSearchMatch(_ match: SessionSearchMatch) {
        selectedSearchMatch = match
        selectedSessionSource = match.source
        loadConversation(source: match.sourceURL, provider: match.provider)
    }

    var selectedSearchMatchForDetail: SessionSearchMatch? {
        guard let selectedSessionSource,
              selectedSearchMatch?.source == selectedSessionSource else { return nil }
        return selectedSearchMatch
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
        let token = UUID()
        for source in wanted { sessionTitleRequestTokens[source] = token }
        let root = projectRoot
        startTrackedApplicationTask(scope: .workScreen) { [weak self] in
            guard let self else { return }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                finishSessionTitleRequest(
                    sources: wanted,
                    token: token,
                    fetched: [:],
                    cancelled: Task.isCancelled
                )
                return
            }
            let fetched = await ScreeService.titles(execution: execution, sources: wanted)
            finishSessionTitleRequest(
                sources: wanted,
                token: token,
                fetched: fetched,
                cancelled: Task.isCancelled
            )
        }
    }

    /// Same fetch as `loadConversation(for:)`, for a browser row that has
    /// a transcript but no binding to any repo.
    func loadConversation(for entry: SessionIndexEntry, retry: Bool = false) {
        loadConversation(source: entry.sourceURL, provider: entry.provider, retry: retry)
    }

    /// The fetch itself, given only a transcript. Every caller that has a
    /// path can use it, whether or not the session is in the index.
    func loadConversation(source: URL, provider: SessionProvider, retry: Bool = false) {
        let entrySource = source.path
        let key = Self.conversationKey(
            provider: provider, sessionID: entrySource, source: source
        )
        if retry {
            conversationLoads[key] = nil
        } else if conversationLoads[key] != nil {
            return
        }
        conversationLoads[key] = .loading
        let token = UUID()
        conversationLoadTokens[key] = token
        let root = projectRoot
        startTrackedApplicationTask(scope: .workScreen) { [weak self] in
            guard let self else { return }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                finishConversationLoad(
                    key: key,
                    token: token,
                    state: Task.isCancelled
                        ? nil
                        : .failed("서명된 실행 런타임을 확인하지 못했습니다.")
                )
                return
            }
            guard !Task.isCancelled else {
                finishConversationLoad(key: key, token: token, state: nil)
                return
            }
            let state: ConversationLoadState
            switch await ScreeService.inspect(execution: execution, source: source) {
            case .success(let conversation):
                state = .loaded(conversation)
            case .failure(let error):
                state = .failed(error.message)
            }
            finishConversationLoad(
                key: key,
                token: token,
                state: Task.isCancelled ? nil : state
            )
        }
    }

    @discardableResult
    func finishConversationLoad(
        key: String,
        token: UUID,
        state: ConversationLoadState?
    ) -> Bool {
        guard conversationLoadTokens[key] == token else { return false }
        conversationLoadTokens[key] = nil
        conversationLoads[key] = state
        return true
    }

    func finishSessionTitleRequest(
        sources: [String],
        token: UUID,
        fetched: [String: SessionTitle],
        cancelled: Bool
    ) {
        let current = Set(sources.filter { sessionTitleRequestTokens[$0] == token })
        guard !current.isEmpty else { return }
        if !cancelled {
            sessionTitles.merge(fetched.filter { current.contains($0.key) }) { _, new in new }
        }
        for source in current {
            sessionTitleRequestTokens[source] = nil
            titleRequests.remove(source)
        }
    }

    func conversationState(for entry: SessionIndexEntry) -> ConversationLoadState? {
        conversationState(source: entry.sourceURL, provider: entry.provider)
    }

    func conversationState(
        source: URL,
        provider: SessionProvider
    ) -> ConversationLoadState? {
        conversationLoads[Self.conversationKey(
            provider: provider, sessionID: source.path, source: source
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
        guard candidateTitleRequestTokens[target.id] == nil else { return }
        let token = UUID()
        candidateTitleRequestTokens[target.id] = token
        startTrackedApplicationTask(scope: .workScreen) { [weak self] in
            guard let self else { return }
            defer {
                if candidateTitleRequestTokens[target.id] == token {
                    candidateTitleRequestTokens[target.id] = nil
                }
            }
            let titles = await MothballService.titles(for: target, projectRoot: root)
            guard !Task.isCancelled,
                  candidateTitleRequestTokens[target.id] == token else { return }
            guard let current = repoAssessments?.firstIndex(where: { $0.id == target.id })
            else { return }
            repoAssessments?[current].presentations = titles
        }
    }

    func refreshArchiveCandidates() {
        guard let report = screeReport else {
            archiveError = "작업 감사를 먼저 실행해야 저장소를 판정할 수 있습니다."
            return
        }
        let root = projectRoot
        let paths = report.lineagePaths
        refreshArchiveCandidates(
            using: { await MothballService.scanCandidates(lineagePaths: paths) },
            binding: { candidates in
                await MothballService.withContinuity(candidates, projectRoot: root)
            }
        )
    }

    /// Internal injection keeps cancellation and newest-request behavior
    /// testable without spawning Git and Python processes. Production always
    /// enters through the zero-argument method above.
    func refreshArchiveCandidates(
        using scan: @escaping () async -> RepoScanOutcome,
        binding bind: @escaping ([ArchiveCandidate]) async -> [ArchiveCandidate]
    ) {
        guard !applicationTerminationStarted else { return }
        cancelAndRetainForDrain(archiveTask)
        archiveGeneration += 1
        let generation = archiveGeneration
        archiveLoading = true
        archiveBindingComplete = false
        archiveError = nil
        archiveTask = Task {
            let outcome = await scan()
            guard !Task.isCancelled, generation == archiveGeneration else { return }
            // Show the git judgment first, then fill in session bindings:
            // binding spawns one subprocess per repo, and a long wait for
            // it would otherwise hold back a list that is already useful.
            // Until it lands every row reads "AI 세션 확인 안 됨", which is
            // true rather than reassuring.
            repoAssessments = outcome.candidates
            repoScanFailures = outcome.failures
            reposNotScanned = outcome.notScanned
            archiveInspectionFailures = outcome.failureCount
            // Binding is for repos there is a retirement to review. It
            // reads every session store per pass, and running it over
            // repos that can never be archived -- the `.unsafe` ones,
            // which are `.unsafe` precisely because they hold live work
            // -- spends that pass on a question nobody asked. The
            // ineligible keep their assessment and their `.notAssessed`
            // continuity, which is the honest answer for them.
            let eligible = outcome.candidates.filter(\.isRetirementEligible)
            guard !eligible.isEmpty else {
                archiveBindingComplete = true
                archiveLoading = false
                archiveTask = nil
                return
            }
            let bound = await bind(eligible)
            guard !Task.isCancelled, generation == archiveGeneration else { return }
            var byPath: [String: ArchiveCandidate] = [:]
            for candidate in bound { byPath[candidate.pathText] = candidate }
            repoAssessments = outcome.candidates.map { byPath[$0.pathText] ?? $0 }
            guard generation == archiveGeneration else { return }
            archiveBindingComplete = true
            archiveLoading = false
            archiveTask = nil
        }
    }
}
