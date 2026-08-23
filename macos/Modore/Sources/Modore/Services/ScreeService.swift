import AppKit
import Foundation
import MothballCore

/// Runs the sealed `scree.py` and parses its output. Read-only: this never
/// deletes anything.
///
/// A `report` retains no session content — scree's own contract
/// guarantees that and this layer only decodes the JSON. Two commands
/// deliberately read inside a conversation, both for one session the
/// user named: `preserve`, which exports a masked transcript, and
/// `title`, which returns one masked line to show beside a deletion
/// decision. Neither runs during a scan.
enum ScreeOutcome {
    case success(ScreeReport)
    case failure(String)
}

/// `preserve` is scree's one deliberate exception to its no-content contract
/// (see scree.py's module docstring): a single, explicitly-named session
/// file, exported as masked Markdown. `.success` carries the file it wrote.
enum ScreePreserveOutcome {
    case success(URL)
    case failure(String)
}

enum ScreeService {
    static func run(projectRoot: URL) async -> ScreeOutcome {
        switch await invoke(projectRoot: projectRoot, arguments: ["report", "--json"], timeout: 180) {
        case .failure(let message):
            return .failure(message)
        case .timedOut:
            return .failure("scree가 3분 안에 끝나지 않았습니다. 세션·워크트리가 많으면 시간이 더 걸릴 수 있습니다.")
        case .success(let output):
            guard let start = output.firstIndex(of: "{") else {
                return .failure("scree 출력에서 JSON을 찾지 못했습니다.")
            }
            let jsonSlice = output[start...]
            guard let data = jsonSlice.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let report = ScreeReport(json: object) else {
                return .failure("scree 출력을 해석하지 못했습니다.")
            }
            return .success(report)
        }
    }

    /// `source` must be a session file path scree itself already reported
    /// (e.g. an expiring session's `source`) — never arbitrary user text.
    /// The destination lives under the app's own results directory, the
    /// same mutable, ownership-checked location every other Modore output
    /// already writes to; scree.py's own `--out` handling creates it.
    static func preserve(projectRoot: URL, tool: String, source: String) async -> ScreePreserveOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure("서명된 실행 런타임을 확인하지 못해 scree를 실행하지 않았습니다.")
        }
        let destination = execution.outputRoot
            .appendingPathComponent("scree-preserve")
            .appendingPathComponent(preserveFilename(tool: tool, source: source))
        switch await invoke(
            execution: execution,
            arguments: ["preserve", source, "--out", destination.path],
            timeout: 60
        ) {
        case .failure(let message):
            return .failure(message)
        case .timedOut:
            return .failure("보존 내보내기가 1분 안에 끝나지 않았습니다.")
        case .success:
            return .success(destination)
        }
    }

    /// Pure and independently testable: a stable, readable export filename
    /// from `tool` (one of scree's own fixed labels) and the session file's
    /// basename. Both are sanitized defensively rather than trusted verbatim
    /// — this becomes a filesystem path component.
    static func preserveFilename(tool: String, source: String) -> String {
        let stem = ((source as NSString).lastPathComponent as NSString).deletingPathExtension
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        func sanitize(_ value: String) -> String {
            let cleaned = String(value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            return cleaned.isEmpty ? "session" : cleaned
        }
        return "\(sanitize(tool))-\(sanitize(stem)).md"
    }
}

/// A binder run's verdict plus, when it failed, why.
///
/// The assessment alone is not enough to act on. Every failure here
/// collapses to `.notAssessed`, which is correct — a binder that could
/// not run has established nothing — but it is also indistinguishable
/// from a binder that ran and could not reach a conclusion. If the
/// subprocess path ever breaks, every workspace reads "확인 안 됨" and
/// every archive refuses, with nothing anywhere saying the tool is
/// broken rather than the repos being unassessed. The diagnostic is what
/// tells those apart.
struct ScreeBindOutcome {
    let assessment: ContinuityAssessment
    /// nil when the binder ran and answered. Non-nil means the answer is
    /// `.notAssessed` because something went wrong, not because the
    /// binder said so.
    let diagnostic: String?

    static func failed(_ reason: String) -> ScreeBindOutcome {
        ScreeBindOutcome(assessment: .notAssessed, diagnostic: reason)
    }
}

extension ScreeService {
    /// Runs `scree.py bind` for one workspace and decodes the result into
    /// the assessment MothballCore's gate reads.
    ///
    /// Failure never becomes a permissive assessment: a timed-out or
    /// unparseable binder run is, for deciding whether a workspace may be
    /// retired, exactly the same as never having run one.
    static func bind(
        projectRoot: URL,
        workspace: URL,
        repoURL: String?,
        deep: Bool = false
    ) async -> ScreeBindOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failed("서명된 실행 런타임을 확인하지 못해 세션 바인더를 실행하지 않았습니다.")
        }
        return await bind(execution: execution, workspace: workspace,
                          repoURL: repoURL, deep: deep)
    }

    /// Execution-injecting overload, mirroring `invoke`'s own split.
    ///
    /// It exists so the subprocess path can be tested. The two halves of
    /// this feature are written in different languages and meet over a
    /// pipe; unit tests on either side pass while the pipe is broken, and
    /// a broken pipe fails closed and silent. Without an injection point
    /// the only way to exercise it is to launch the app.
    /// - Parameter homeOverride: session-store root, for tests that need
    ///   a hermetic fake home instead of the machine's real history.
    ///   scree's own `--home` flag is already suppressed from its help for
    ///   the same reason.
    static func bind(
        execution: RuntimeExecutionContext,
        workspace: URL,
        repoURL: String?,
        deep: Bool = false,
        homeOverride: URL? = nil
    ) async -> ScreeBindOutcome {
        var arguments = ["bind", workspace.path]
        if let repoURL, !repoURL.isEmpty { arguments += ["--repo-url", repoURL] }
        if deep { arguments.append("--deep") }
        if let homeOverride { arguments += ["--home", homeOverride.path] }

        switch await invoke(execution: execution, arguments: arguments, timeout: 120) {
        case .failure(let message):
            return .failed(message)
        case .timedOut:
            return .failed("세션 바인딩이 2분 안에 끝나지 않았습니다.")
        case .success(let output):
            guard let start = output.firstIndex(of: "{"),
                  let data = output[start...].data(using: .utf8) else {
                return .failed("세션 바인더 출력에서 JSON을 찾지 못했습니다.")
            }
            let assessment = ContinuityAssessment.fromBindReport(data)

            // Escalate on coverage, not on emptiness. A shallow pass that
            // turned up one Codex session has still not looked for the
            // Claude session that ran from a parent directory -- gating
            // the retry on "found nothing" means the moment a scan finds
            // anything it stops looking, which is the opposite of what a
            // completeness check is for.
            if !deep, assessment.coverage != .complete, Self.isWellFormed(data) {
                return await bind(execution: execution, workspace: workspace,
                                  repoURL: repoURL, deep: true,
                                  homeOverride: homeOverride)
            }

            if case .notAssessed = assessment {
                guard Self.isWellFormed(data) else {
                    // JSON this build could not read as a completed
                    // assessment -- schema drift between the two
                    // languages, not a repo with unknown sessions.
                    return .failed("세션 바인더 출력을 해석하지 못했습니다.")
                }
                // Already the deepest pass available and it still stopped
                // short. Saying which gap remains beats reporting a parse
                // failure that did not happen.
                return .failed(Self.incompleteScanReason(data))
            }
                        return ScreeBindOutcome(assessment: assessment, diagnostic: nil)
        }
    }

    /// Says which gap left the scan short, because the gaps close
    /// differently: an unreadable transcript is a permissions problem, a
    /// store with no binder is a missing feature, and "검사가 완전하지
    /// 않았습니다" sends the user looking for neither.
    static func incompleteScanReason(_ data: Data) -> String {
        guard let report = try? BindReport.decoder().decode(BindReport.self, from: data),
              let detail = report.coverageDetail else {
            return "세션 검사가 끝까지 진행되지 않아 연결 여부를 확정하지 못했습니다."
        }
        if let unbound = detail.unboundStores, !unbound.isEmpty {
            return "\(unbound.joined(separator: "·")) 세션 저장소는 아직 검사하지 않습니다. "
                + "이 저장소에 연결된 대화가 없다고 단정할 수 없습니다."
        }
        let stalled = [("Claude", detail.claude), ("Codex", detail.codex)]
            .filter { $0.1 != nil && $0.1 != "complete" }
            .map(\.0)
        if !stalled.isEmpty {
            return "\(stalled.joined(separator: "·")) 세션 일부를 읽지 못해 연결 여부를 확정하지 못했습니다."
        }
        return "세션 검사가 끝까지 진행되지 않아 연결 여부를 확정하지 못했습니다."
    }

    /// True when the binder produced a payload this build understands as
    /// a finished run. Separates "the scan was limited" from "the two
    /// languages disagree about the format", which need different answers.
    static func isWellFormed(_ data: Data) -> Bool {
        guard let report = try? BindReport.decoder().decode(BindReport.self, from: data) else {
            return false
        }
        return report.assessed
    }
}

extension ScreeService {
    /// Reads a one-line title for a session the caller names.
    ///
    /// Display only. The result never reaches `ContinuityAssessment` or
    /// the gate: a title is a guess at what a conversation was about, and
    /// nothing that decides whether a workspace may be deleted is allowed
    /// to rest on a guess. It is also the first thing this app keeps from
    /// the inside of a conversation, so it stays masked, one line, and
    /// fetched for the handful of sessions actually shown.
    static func title(
        execution: RuntimeExecutionContext,
        binding: SessionBinding,
        homeOverride: URL? = nil
    ) async -> SessionPresentation? {
        var arguments = ["title", binding.source.path,
                         "--label", binding.provider.displayName + " 작업"]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        guard case .success(let output) = await invoke(
            execution: execution, arguments: arguments, timeout: 30
        ), let start = output.firstIndex(of: "{"),
           let data = output[start...].data(using: .utf8),
           let decoded = try? JSONDecoder().decode(TitlePayload.self, from: data) else {
            return nil
        }
        let modified = (try? binding.source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return SessionPresentation(
            provider: binding.provider,
            sessionID: binding.sessionID,
            title: decoded.title,
            titleSource: TitleSource(rawValue: decoded.titleSource) ?? .date,
            lastActiveAt: modified,
            sizeBytes: binding.sizeBytes
        )
    }

    /// Binds many workspaces in one pass.
    ///
    /// A shallow pass never establishes completeness, so every candidate
    /// on the screen needs a deep look -- and asking one repo at a time
    /// re-reads the whole session store per repo. Measured here: 12.8
    /// minutes across 53 candidates one by one, 2.8 minutes in a single
    /// pass, with every candidate reaching complete coverage either way.
    static func bindAll(
        execution: RuntimeExecutionContext,
        targets: [(workspace: URL, repoURL: String?)],
        deep: Bool = true,
        homeOverride: URL? = nil
    ) async -> [String: ScreeBindOutcome] {
        guard !targets.isEmpty else { return [:] }
        let payload = targets.map { target in
            ["workspace": target.workspace.path, "repoUrl": target.repoURL as Any]
        }
        // Written to a file rather than passed as arguments: a screen can
        // carry fifty candidates and their absolute paths, which is past
        // what a command line should be asked to hold.
        let listing = execution.outputRoot.appending(path: "scree-bind-targets.json")
        guard let input = try? JSONSerialization.data(withJSONObject: payload),
              (try? input.write(to: listing, options: [.atomic])) != nil else {
            return failAll(targets, "바인딩 대상 목록을 기록하지 못했습니다.")
        }
        defer { try? FileManager.default.removeItem(at: listing) }

        // The answer goes to a file too. It grows with the machine's
        // session count -- 8,424 bindings across 53 candidates here, past
        // the runner's output ceiling -- and a limit that exists to stop a
        // runaway subprocess is the wrong thing to raise for a result
        // that is legitimately large.
        let resultFile = execution.outputRoot.appending(path: "scree-bind-results.json")
        try? FileManager.default.removeItem(at: resultFile)
        defer { try? FileManager.default.removeItem(at: resultFile) }

        var arguments = ["bind-all", "--targets", listing.path, "--out", resultFile.path]
        if deep { arguments.append("--deep") }
        if let homeOverride { arguments += ["--home", homeOverride.path] }

        // A full content scan of every store; the per-repo timeout would
        // be the wrong budget for one pass over all of them.
        switch await invoke(execution: execution, arguments: arguments, timeout: 900) {
        case .failure(let message):
            return failAll(targets, message)
        case .timedOut:
            return failAll(targets, "세션 바인딩이 15분 안에 끝나지 않았습니다.")
        case .success:
            guard let data = try? Data(contentsOf: resultFile),
                  let decoded = try? BindReport.decoder().decode(BatchPayload.self, from: data) else {
                return failAll(targets, "세션 바인더 출력을 해석하지 못했습니다.")
            }
            var out: [String: ScreeBindOutcome] = [:]
            for target in targets {
                guard let report = decoded.results[target.workspace.path],
                      let encoded = try? JSONEncoder().encode(report) else {
                    out[target.workspace.path] = .failed("이 저장소에 대한 바인딩 결과가 없습니다.")
                    continue
                }
                let assessment = ContinuityAssessment.fromBindReport(encoded)
                if case .notAssessed = assessment {
                    out[target.workspace.path] = .failed(Self.incompleteScanReason(encoded))
                } else {
                    out[target.workspace.path] = ScreeBindOutcome(
                        assessment: assessment, diagnostic: nil
                    )
                }
            }
            return out
        }
    }

    private struct BatchPayload: Decodable {
        let results: [String: BindReport]
    }

    private static func failAll(
        _ targets: [(workspace: URL, repoURL: String?)], _ reason: String
    ) -> [String: ScreeBindOutcome] {
        Dictionary(uniqueKeysWithValues: targets.map { ($0.workspace.path, .failed(reason)) })
    }

    /// Digest of every bindable session store right now.
    ///
    /// Read again before a retire so a binding taken minutes ago is not
    /// acted on as though the stores had stood still. A timestamp would
    /// answer the wrong question -- the point is whether this is the same
    /// set of candidates that was judged, which a rewritten or deleted
    /// file changes as much as a new one.
    static func storeFingerprint(
        execution: RuntimeExecutionContext,
        homeOverride: URL? = nil
    ) async -> BindReport.Fingerprint? {
        var arguments = ["fingerprint"]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        guard case .success(let output) = await invoke(
            execution: execution, arguments: arguments, timeout: 60
        ), let start = output.firstIndex(of: "{"),
           let data = output[start...].data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(BindReport.Fingerprint.self, from: data)
    }

    /// One session's conversation for display, via `scree.py inspect`.
    ///
    /// The judgment plane never sees this: it is fetched when a person
    /// opens a session, rendered, and discarded. Masked by default at
    /// the source; nothing here re-requests raw.
    /// Returns the failure as a sentence rather than `nil`. A caller that
    /// only learns "no conversation" has nothing to show and nothing to
    /// retry from, and the screen it drives sits on a spinner forever.
    static func inspect(
        execution: RuntimeExecutionContext,
        binding: SessionBinding,
        turns: Int = 20,
        homeOverride: URL? = nil
    ) async -> Result<SessionConversation, ScreeInspectionError> {
        await inspect(
            execution: execution, source: binding.source,
            turns: turns, homeOverride: homeOverride
        )
    }

    /// Takes the transcript itself rather than a binding: the session
    /// browser lists what the machine holds, which is not always bound to
    /// any repo, and `inspect` never needed more than the path.
    static func inspect(
        execution: RuntimeExecutionContext,
        source: URL,
        turns: Int = 20,
        homeOverride: URL? = nil
    ) async -> Result<SessionConversation, ScreeInspectionError> {
        var arguments = ["inspect", source.path, "--turns", String(turns)]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        let outcome = await invoke(execution: execution, arguments: arguments, timeout: 60)
        let output: String
        switch outcome {
        case .success(let value): output = value
        case .timedOut: return .failure(.init(message: "대화를 읽는 데 시간이 너무 걸려 중단했습니다."))
        case .failure(let message): return .failure(.init(message: message))
        }
        guard let start = output.firstIndex(of: "{"),
              let data = output[start...].data(using: .utf8),
              let conversation = try? JSONDecoder().decode(
                SessionConversation.self, from: data
              ) else {
            return .failure(.init(message: "scree가 돌려준 대화 형식을 읽지 못했습니다."))
        }
        return .success(conversation)
    }

    /// The metadata index behind the session browser, via `scree.py
    /// sessions`. No transcript body is read to build this.
    /// `limit` 0 means every session. It has to: a cap here is invisible
    /// to the person searching, who is told the machine holds 7,205
    /// sessions and then silently allowed to search only the newest few
    /// hundred of them. Measured, the full walk costs about half a second
    /// -- the cap was never buying the I/O it appeared to.
    static func sessions(
        execution: RuntimeExecutionContext,
        limit: Int = 0,
        homeOverride: URL? = nil
    ) async -> Result<SessionIndex, ScreeInspectionError> {
        // The answer goes to a file, like `bind-all`'s: a full index runs
        // to several megabytes, past the runner's output ceiling, and
        // that ceiling exists to stop a runaway subprocess rather than to
        // bound a result that is legitimately this large.
        let resultFile = execution.outputRoot
            .appending(path: "scree-sessions-\(UUID().uuidString).json")
        try? FileManager.default.removeItem(at: resultFile)
        defer { try? FileManager.default.removeItem(at: resultFile) }

        var arguments = ["sessions", "--limit", String(limit), "--out", resultFile.path]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        switch await invoke(execution: execution, arguments: arguments, timeout: 180) {
        case .timedOut:
            return .failure(.init(message: "세션 목록을 읽는 데 시간이 너무 걸려 중단했습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        case .success:
            guard let data = try? Data(contentsOf: resultFile),
                  let index = try? JSONDecoder().decode(SessionIndex.self, from: data) else {
                return .failure(.init(message: "scree가 돌려준 세션 목록 형식을 읽지 못했습니다."))
            }
            return .success(index)
        }
    }

    /// Content search across every session, via `scree.py search`.
    ///
    /// Runs only when a person types a query and presses return -- the
    /// judgment plane never calls this, and nothing it returns reaches a
    /// verdict. Masked at the source.
    static func search(
        execution: RuntimeExecutionContext,
        query: String,
        limit: Int = 200,
        homeOverride: URL? = nil
    ) async -> Result<SessionSearchResult, ScreeInspectionError> {
        let resultFile = execution.outputRoot
            .appending(path: "scree-search-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: resultFile) }

        var arguments = ["search", query, "--limit", String(limit), "--out", resultFile.path]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        switch await invoke(execution: execution, arguments: arguments, timeout: 180) {
        case .timedOut:
            return .failure(.init(message: "검색이 시간 안에 끝나지 않았습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        case .success:
            guard let data = try? Data(contentsOf: resultFile),
                  let decoded = try? JSONDecoder().decode(SessionSearchResult.self, from: data) else {
                return .failure(.init(message: "검색 결과를 해석하지 못했습니다."))
            }
            return .success(decoded)
        }
    }

    /// Titles for many named sessions in one pass.
    ///
    /// The per-session call is right for one session and wrong for a
    /// list: a screen showing thirty rows paid thirty process spawns,
    /// serially, which is why rows sat on "제목을 읽는 중…" long enough
    /// to look broken.
    static func titles(
        execution: RuntimeExecutionContext,
        sources: [String],
        homeOverride: URL? = nil
    ) async -> [String: SessionTitle] {
        guard !sources.isEmpty,
              let payload = try? JSONSerialization.data(withJSONObject: sources) else {
            return [:]
        }
        // A file, not arguments, for the same reason `bind-all` uses one:
        // a screen's worth of absolute paths is past what a command line
        // should be asked to hold.
        //
        // Unique per call, because these overlap. A list renders many rows
        // at once and each asks for its own titles; a shared filename let
        // one call overwrite another's input and then delete it out from
        // under a subprocess that was still starting, so every row stayed
        // on "제목을 읽는 중…" forever.
        let listing = execution.outputRoot
            .appending(path: "scree-title-sources-\(UUID().uuidString).json")
        guard (try? payload.write(to: listing, options: [.atomic])) != nil else { return [:] }
        defer { try? FileManager.default.removeItem(at: listing) }

        var arguments = ["titles", "--sources", listing.path]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        guard case .success(let output) = await invoke(
            execution: execution, arguments: arguments, timeout: 120
        ), let start = output.firstIndex(of: "{"),
           let data = output[start...].data(using: .utf8),
           let decoded = try? JSONDecoder().decode(
            TitlesPayload.self, from: data
           ) else {
            return [:]
        }
        return decoded.titles
    }

    private struct TitlesPayload: Decodable {
        let titles: [String: SessionTitle]
    }

    private struct TitlePayload: Decodable {
        let title: String
        let titleSource: String
    }

    private enum RawOutcome {
        case success(String)
        case timedOut
        case failure(String)
    }

    private static func invoke(
        projectRoot: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> RawOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure("서명된 실행 런타임을 확인하지 못해 scree를 실행하지 않았습니다.")
        }
        return await invoke(execution: execution, arguments: arguments, timeout: timeout)
    }

    private static func invoke(
        execution: RuntimeExecutionContext,
        arguments: [String],
        timeout: TimeInterval
    ) async -> RawOutcome {
        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/scree.py",
            name: "scree"
        ) else {
            return .failure("봉인한 scree 스크립트를 확인하지 못해 실행하지 않았습니다.")
        }
        guard let python3 = Self.python3Path else {
            return .failure("python3을 찾지 못해 scree를 실행하지 않았습니다.")
        }

        // `invocation.argument` is a pinned-file placeholder that LocalProcessRunner
        // rewrites to "/dev/fd/N" at spawn time — the same mechanism every bash
        // script here already uses. CPython's own main-script loader silently
        // fails on that form specifically: verified directly (isolated repro)
        // that `python3 /dev/fd/N` as the *script argument* exits 0 with zero
        // bytes of output and no stderr — while `cat /dev/fd/N` and an explicit
        // `open('/dev/fd/N').read()` from Python code both read the real content
        // correctly on the identical descriptor. So the descriptor and the
        // pinning mechanism are both fine; only CPython's argv[1]-as-script-path
        // handling of an fdescfs path is the problem. Route around it: pass the
        // pinned path as a plain argument instead and read it explicitly with
        // `-c`, executing it with __name__ == "__main__" so scree.py's own
        // entry guard still fires and argparse still sees a normal argv.
        let wrapper = """
        import sys
        path = sys.argv[1]
        sys.argv = ["scree.py"] + sys.argv[2:]
        source = open(path, "rb").read()
        exec(compile(source, "scree.py", "exec"), {"__name__": "__main__", "__file__": "scree.py"})
        """
        let result = await LocalProcessRunner.capture(
            executable: python3,
            arguments: ["-c", wrapper, invocation.argument] + arguments,
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            timeout: timeout
        )
        guard result.endState != .timedOut else {
            return .timedOut
        }
        guard result.status == 0, result.endState == .exited else {
            return .failure("scree 실행이 실패했습니다 (status \(result.status)).")
        }
        return .success(result.output)
    }

    /// scree.py has no bundled interpreter; this resolves the same fixed,
    /// non-PATH-dependent locations cleanup.sh-style scripts already trust.
    private static let python3Path: String? = {
        for candidate in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }()
}

extension ScanModel {
    func refreshScreeReport() {
        guard !screeLoading else { return }
        screeLoading = true
        screeError = nil
        let root = projectRoot
        Task {
            defer { screeLoading = false }
            switch await ScreeService.run(projectRoot: root) {
            case .success(let report):
                screeReport = report
            case .failure(let message):
                screeError = message
            }
        }
    }

    func preserveScreeSession(_ session: ScreeExpiringSession) {
        guard screePreserveInFlightSource == nil else { return }
        screePreserveInFlightSource = session.source
        errorMessage = nil
        let root = projectRoot
        let tool = session.tool
        let source = session.source
        Task {
            defer { screePreserveInFlightSource = nil }
            switch await ScreeService.preserve(projectRoot: root, tool: tool, source: source) {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appendLog("세션 보존: \(url.lastPathComponent)")
                AccessibilityAnnouncer.announce("세션을 보존했습니다")
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    /// Exports one session bound to an archive candidate, through the same
    /// masked single-session path the expiring-session list already uses.
    ///
    /// A count and a size say a delete would cost something; they do not
    /// say what. Reading the conversation back is the only way to judge
    /// whether it was worth keeping, and that judgement belongs to the
    /// person about to approve the delete -- so the export is reachable
    /// from the row where they decide, not only from the session page.
    func preserveBoundSession(_ binding: SessionBinding) {
        guard screePreserveInFlightSource == nil else { return }
        let source = binding.source.path
        screePreserveInFlightSource = source
        errorMessage = nil
        let root = projectRoot
        // Every provider's own label. A binary Claude-or-Codex choice
        // filed Gemini exports under "Codex", which is wrong in the one
        // place a user later goes looking for them.
        let tool = binding.provider.displayName
        Task {
            defer { screePreserveInFlightSource = nil }
            switch await ScreeService.preserve(projectRoot: root, tool: tool, source: source) {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appendLog("세션 보존: \(url.lastPathComponent)")
                AccessibilityAnnouncer.announce("세션을 보존했습니다")
            case .failure(let message):
                errorMessage = message
            }
        }
    }
}
