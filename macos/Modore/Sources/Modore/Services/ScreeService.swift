import AppKit
import Darwin
import Foundation
import MothballCore

/// Runs the sealed `scree.py` and parses its output. Audits are read-only;
/// explicit exports and backups write separate outputs, never deleting sources.
///
/// `report` and ordinary inventory paths are metadata-only. Explicit
/// owner-requested inspection and search commands may read transcript bodies;
/// `scree.py`'s module-level content-reading contract is the authoritative
/// list. Raw transcript content is never fed to a safety verdict; deep binding
/// emits only derived binding evidence and does not retain the body.
enum ScreeOutcome {
    case success(ScreeReport)
    case failure(String)
}

/// `preserve` is an explicit content-reading command (see scree.py's module
/// contract): a single, explicitly-named session file exported as masked
/// Markdown. `.success` carries the file it wrote.
enum ScreePreserveOutcome {
    case success(URL)
    case failure(String)
}

struct SessionBackupReceipt: Decodable {
    let schemaVersion: Int
    let status: String
    let archive: String
    let provider: String
    let scope: String?
    let sourceRelative: String
    let fileCount: Int
    let totalBytes: Int64
    let categories: [String]
    let excluded: [String]
    let masked: Bool
    let encrypted: Bool
    let restoredRoot: String?
    let restoredSource: String?

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(provider) · \(fileCount)개 파일 · 원본 \(size) · SHA-256 일치"
    }

    var includedDescription: String {
        let labels = [
            "metadata": "세션 메타데이터",
            "transcript": "대화 원본",
            "audit": "감사 기록",
            "subagents": "서브에이전트",
            "queue": "작업 큐",
            "outputs": "작업 산출물",
            "tool-results": "도구 결과",
            "file-history": "파일 스냅샷",
            "image-cache": "이미지",
            "uploads": "첨부 파일",
            "sidecar": "보조 파일",
        ]
        return categories.compactMap { labels[$0] }.joined(separator: " · ")
    }
}

enum SessionBackupOperation {
    case create(source: String, destination: URL)
    case verify(URL)
    case restore(archive: URL, destination: URL)

    var arguments: [String] {
        switch self {
        case .create(let source, let destination):
            return ["backup", source, "--out", destination.path, "--include-sensitive"]
        case .verify(let archive):
            return ["backup-verify", archive.path]
        case .restore(let archive, let destination):
            return ["backup-restore", archive.path, "--out", destination.path]
        }
    }

    var expectedStatus: String {
        if case .restore = self { return "restored" }
        return "verified"
    }
}

enum ScreeService {
    static func sessionBackup(
        projectRoot: URL, operation: SessionBackupOperation
    ) async -> Result<SessionBackupReceipt, ScreeInspectionError> {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure(.init(message: "서명된 실행 런타임을 확인하지 못했습니다."))
        }
        return await sessionBackup(execution: execution, operation: operation)
    }

    static func sessionBackup(
        execution: RuntimeExecutionContext, operation: SessionBackupOperation,
        homeOverride: URL? = nil
    ) async -> Result<SessionBackupReceipt, ScreeInspectionError> {
        var arguments = operation.arguments
        if case .create = operation, let homeOverride {
            arguments += ["--home", homeOverride.path]
        }
        // Raw backup/restore installs a SIGTERM cleanup handler. Do not cut
        // that exact-inode cleanup off with LocalProcessRunner's ordinary
        // one-second SIGKILL. A finite one-minute ceiling still prevents a
        // blocked volume from leaving an untracked Python process forever;
        // the UI returns its bounded timeout while cleanup continues.
        switch await invoke(
            execution: execution,
            arguments: arguments,
            timeout: 300,
            forceKillAfterTermination: 60,
            waitForCleanupOnStop: true
        ) {
        case .timedOut:
            return .failure(.init(message: "5분 안에 검증을 마치지 못했습니다. 백업·복원 성공으로 표시하지 않습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        case .success(let output):
            guard let data = output.data(using: .utf8),
                  let receipt = try? JSONDecoder().decode(SessionBackupReceipt.self, from: data),
                  receipt.schemaVersion == 1, receipt.status == operation.expectedStatus,
                  receipt.fileCount > 0 else {
                return .failure(.init(message: "백업 검증 결과를 해석하지 못했습니다."))
            }
            return .success(receipt)
        }
    }

    static func run(projectRoot: URL) async -> ScreeOutcome {
        // The worktree portion owns a shorter internal isolation deadline, and
        // the full metadata report is measured in seconds. Keep an outer UI
        // ceiling as defense in depth: a TCC- or filesystem-blocked syscall
        // must never leave the Work screen claiming to run for minutes.
        switch await invoke(projectRoot: projectRoot, arguments: ["report", "--json"], timeout: 30) {
        case .failure(let message):
            return .failure(message)
        case .timedOut:
            return .failure("작업 감사가 30초 안에 끝나지 않아 중단했습니다. 읽기 제한 경로는 결과 없음으로 단정하지 않습니다.")
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
            return .failure("대화 내보내기가 1분 안에 끝나지 않았습니다.")
        case .success(let output):
            guard let actual = validatedPreserveOutput(
                output,
                expectedParent: destination.deletingLastPathComponent()
            ) else {
                return .failure("대화 내보내기 결과 경로를 안전하게 확인하지 못했습니다.")
            }
            return .success(actual)
        }
    }

    private struct PreservePayload: Decodable {
        let status: String
        let output: String
        let masked: Bool
    }

    /// The Python writer may choose a random create-only filename when the
    /// readable default already exists. Trust that returned path only after
    /// rechecking it as an owner-only regular file in the exact output parent.
    static func validatedPreserveOutput(
        _ output: String,
        expectedParent: URL
    ) -> URL? {
        guard let start = output.firstIndex(of: "{"),
              let data = String(output[start...]).data(using: .utf8),
              let payload = try? JSONDecoder().decode(PreservePayload.self, from: data),
              payload.status == "preserved",
              payload.masked else {
            return nil
        }
        let candidate = URL(fileURLWithPath: payload.output).standardizedFileURL
        let parent = expectedParent.standardizedFileURL
        guard candidate.isFileURL,
              candidate.deletingLastPathComponent().path == parent.path,
              candidate.pathExtension.lowercased() == "md" else {
            return nil
        }
        var value = stat()
        let status = candidate.path.withCString { Darwin.lstat($0, &value) }
        guard status == 0,
              value.st_mode & S_IFMT == S_IFREG,
              value.st_uid == Darwin.geteuid(),
              value.st_mode & 0o077 == 0 else {
            return nil
        }
        return candidate
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
        let stalled = [
            ("Claude Code", detail.claude),
            ("Claude Desktop", detail.claudeDesktop),
            ("Codex", detail.codex),
        ]
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
        let scratch = bindAllScratchURLs(outputRoot: execution.outputRoot)
        // Written to a file rather than passed as arguments: a screen can
        // carry fifty candidates and their absolute paths, which is past
        // what a command line should be asked to hold. Each run has its own
        // pair: a cancelled pass may still be unwinding while a new Work
        // screen pass starts, and shared names let the old defer delete the
        // new pass's files.
        let listing = scratch.targets
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
        let resultFile = scratch.results
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

    static func bindAllScratchURLs(
        outputRoot: URL,
        runID: UUID = UUID()
    ) -> (targets: URL, results: URL) {
        let suffix = runID.uuidString.lowercased()
        return (
            outputRoot.appending(path: "scree-bind-targets-\(suffix).json"),
            outputRoot.appending(path: "scree-bind-results-\(suffix).json")
        )
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

    /// Reads every physical rollout belonging to one logical task in one
    /// subprocess. The Python side verifies that all sources carry the same
    /// provider task identity before joining their visible turns.
    static func inspect(
        execution: RuntimeExecutionContext,
        sources: [URL],
        turns: Int = 20,
        homeOverride: URL? = nil
    ) async -> Result<SessionConversation, ScreeInspectionError> {
        guard !sources.isEmpty else {
            return .failure(.init(message: "표시할 대화 기록이 없습니다."))
        }
        if sources.count == 1 {
            return await inspect(
                execution: execution, source: sources[0], turns: turns,
                homeOverride: homeOverride)
        }
        guard sources.count <= 64,
              let payload = try? JSONSerialization.data(
                withJSONObject: sources.map(\.path)) else {
            return .failure(.init(message: "대화 기록 조각이 너무 많습니다."))
        }
        let listing = execution.outputRoot
            .appending(path: "scree-inspect-sources-\(UUID().uuidString).json")
        guard (try? payload.write(to: listing, options: [.atomic])) != nil else {
            return .failure(.init(message: "대화 기록 목록을 준비하지 못했습니다."))
        }
        defer { try? FileManager.default.removeItem(at: listing) }

        var arguments = [
            "inspect-many", "--sources", listing.path,
            "--turns", String(turns),
        ]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        let outcome = await invoke(
            execution: execution, arguments: arguments, timeout: 60)
        let output: String
        switch outcome {
        case .success(let value): output = value
        case .timedOut:
            return .failure(.init(message: "대화를 읽는 데 시간이 너무 걸려 중단했습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        }
        guard let start = output.firstIndex(of: "{"),
              let data = output[start...].data(using: .utf8),
              let conversation = try? JSONDecoder().decode(
                SessionConversation.self, from: data) else {
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
        // The phrase goes in a file, not in argv: any local process can
        // read another's command line, and the search query is the most
        // personal thing this tool is ever handed.
        let queryFile = execution.outputRoot
            .appending(path: "scree-query-\(UUID().uuidString).txt")
        guard writePrivateQuery(query, to: queryFile) else {
            return .failure(.init(message: "검색어를 전달하지 못했습니다."))
        }
        defer { try? FileManager.default.removeItem(at: queryFile) }

        var arguments = ["search", "--query-file", queryFile.path, "--limit", String(limit)]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        // The answer comes back on stdout and is never written to disk:
        // a few hundred short snippets fit easily, and a result file
        // would outlive a force quit that skips every `defer`.
        switch await invoke(execution: execution, arguments: arguments, timeout: 180) {
        case .timedOut:
            return .failure(.init(message: "검색이 시간 안에 끝나지 않았습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        case .success(let output):
            guard let start = output.firstIndex(of: "{"),
                  let data = output[start...].data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(SessionSearchResult.self, from: data) else {
                return .failure(.init(message: "검색 결과를 해석하지 못했습니다."))
            }
            return .success(decoded)
        }
    }

    /// Reads the four evidence kinds behind a storage-history question.
    ///
    /// Like content search, this runs only after an explicit submit and
    /// keeps the personal query out of argv. scree owns the 180-second
    /// coverage budget; the process gets another minute to encode and
    /// return that bounded answer before the app stops waiting.
    static func evidence(
        execution: RuntimeExecutionContext,
        query: String,
        limit: Int = 200,
        homeOverride: URL? = nil
    ) async -> Result<ScreeEvidenceResult, ScreeInspectionError> {
        let queryFile = execution.outputRoot
            .appending(path: "scree-evidence-query-\(UUID().uuidString).txt")
        guard writePrivateQuery(query, to: queryFile) else {
            return .failure(.init(message: "질문을 전달하지 못했습니다."))
        }
        defer { try? FileManager.default.removeItem(at: queryFile) }

        var arguments = [
            "evidence", "--query-file", queryFile.path,
            "--limit", String(limit), "--budget-seconds", "180",
        ]
        if let homeOverride { arguments += ["--home", homeOverride.path] }
        switch await invoke(execution: execution, arguments: arguments, timeout: 240) {
        case .timedOut:
            return .failure(.init(message: "이전 기록 확인이 4분 안에 끝나지 않았습니다."))
        case .failure(let message):
            return .failure(.init(message: message))
        case .success(let output):
            guard let start = output.firstIndex(of: "{"),
                  let data = output[start...].data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(
                    ScreeEvidenceResult.self, from: data
                  ) else {
                return .failure(.init(message: "이전 기록 결과를 해석하지 못했습니다."))
            }
            return .success(decoded)
        }
    }

    /// Writes a subprocess query with owner-only permissions. Failure to
    /// establish 0600 is failure to hand the query over, not a best-effort
    /// warning: this file briefly contains transcript search terms.
    static func writePrivateQuery(_ query: String, to url: URL) -> Bool {
        do {
            try Data(query.utf8).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                try? FileManager.default.removeItem(at: url)
                return false
            }
            return true
        } catch {
            try? FileManager.default.removeItem(at: url)
            return false
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

    /// A scree subprocess normally removes these files in `defer`, but a
    /// force-quit never runs that cleanup. Remove only names this exact build
    /// creates, and only after they are old enough that no bounded operation
    /// from another just-replaced app instance can still own them.
    static let scratchCleanupMinimumAge: TimeInterval = 60 * 60

    private static let scratchNameRules: [(prefix: String, extension: String)] = [
        ("scree-query", "txt"),
        ("scree-evidence-query", "txt"),
        ("scree-sessions", "json"),
        ("scree-bind-targets", "json"),
        ("scree-bind-results", "json"),
        ("scree-title-sources", "json"),
        ("scree-inspect-sources", "json"),
    ]

    private struct ScratchIdentity: Equatable {
        let device: UInt64
        let inode: UInt64

        init(_ metadata: stat) {
            device = UInt64(bitPattern: Int64(metadata.st_dev))
            inode = UInt64(metadata.st_ino)
        }
    }

    /// Safely removes force-quit leftovers from the private results directory.
    ///
    /// Every pathname decision is repeated from an already-open directory
    /// descriptor immediately before `unlinkat`. The opened file descriptor is
    /// also matched to the directory entry, so replacing a candidate between
    /// discovery and the final check preserves the replacement. The optional
    /// hook is only a deterministic test seam for that race.
    @discardableResult
    static func cleanupStaleScratchFiles(
        in outputRoot: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = scratchCleanupMinimumAge,
        beforeFinalValidation: ((URL) -> Void)? = nil
    ) -> Int {
        guard outputRoot.isFileURL,
              minimumAge.isFinite, minimumAge >= 0 else { return 0 }
        let cutoff = now.timeIntervalSince1970 - minimumAge
        guard cutoff.isFinite else { return 0 }

        var namedDirectory = stat()
        let namedStatus = outputRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &namedDirectory)
        }
        guard namedStatus == 0,
              isPrivateOwnedDirectory(namedDirectory) else { return 0 }

        let directoryDescriptor = outputRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else { return 0 }
        defer { Darwin.close(directoryDescriptor) }

        var openedDirectory = stat()
        guard Darwin.fstat(directoryDescriptor, &openedDirectory) == 0,
              isPrivateOwnedDirectory(openedDirectory),
              ScratchIdentity(openedDirectory) == ScratchIdentity(namedDirectory) else {
            return 0
        }
        let directoryIdentity = ScratchIdentity(openedDirectory)

        // Enumerate through a duplicate of the verified descriptor. Collect
        // first, then unlink: mutating a directory while readdir is advancing
        // can otherwise skip adjacent entries. A hostile or corrupt results
        // directory is fail-closed rather than an unbounded launch task.
        let enumerationDescriptor = Darwin.dup(directoryDescriptor)
        guard enumerationDescriptor >= 0 else { return 0 }
        guard let stream = Darwin.fdopendir(enumerationDescriptor) else {
            Darwin.close(enumerationDescriptor)
            return 0
        }
        var names: [String] = []
        var entryCount = 0
        var exceededEntryLimit = false
        while let entry = Darwin.readdir(stream) {
            entryCount += 1
            if entryCount > 10_000 {
                exceededEntryLimit = true
                break
            }
            let name = directoryEntryName(entry)
            if isScratchFilename(name) { names.append(name) }
        }
        Darwin.closedir(stream)
        guard !exceededEntryLimit else { return 0 }

        var removed = 0
        for name in names {
            var discovered = stat()
            let discoveredStatus = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &discovered,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            guard discoveredStatus == 0,
                  isEligibleScratchFile(discovered, cutoff: cutoff) else { continue }
            let discoveredIdentity = ScratchIdentity(discovered)

            beforeFinalValidation?(outputRoot.appendingPathComponent(name))

            // Opening after the test seam catches a replacement before any
            // deletion decision. O_NONBLOCK prevents an unexpected special
            // file swapped into the name from blocking this launch path.
            let fileDescriptor = name.withCString {
                Darwin.openat(
                    directoryDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
            guard fileDescriptor >= 0 else { continue }

            var openedFile = stat()
            let openedIsOriginal = Darwin.fstat(fileDescriptor, &openedFile) == 0
                && ScratchIdentity(openedFile) == discoveredIdentity
                && isEligibleScratchFile(openedFile, cutoff: cutoff)
            guard openedIsOriginal else {
                Darwin.close(fileDescriptor)
                continue
            }

            guard directoryStillMatches(
                outputRoot,
                descriptor: directoryDescriptor,
                expected: directoryIdentity
            ) else {
                Darwin.close(fileDescriptor)
                continue
            }

            var finalNamedFile = stat()
            let finalStatus = name.withCString {
                Darwin.fstatat(
                    directoryDescriptor,
                    $0,
                    &finalNamedFile,
                    AT_SYMLINK_NOFOLLOW
                )
            }
            let finalIsOpenedFile = finalStatus == 0
                && ScratchIdentity(finalNamedFile) == ScratchIdentity(openedFile)
                && isEligibleScratchFile(finalNamedFile, cutoff: cutoff)
            guard finalIsOpenedFile else {
                Darwin.close(fileDescriptor)
                continue
            }

            let unlinkStatus = name.withCString {
                Darwin.unlinkat(directoryDescriptor, $0, 0)
            }
            Darwin.close(fileDescriptor)
            if unlinkStatus == 0 { removed += 1 }
        }
        return removed
    }

    private static func isScratchFilename(_ name: String) -> Bool {
        for rule in scratchNameRules {
            let prefix = rule.prefix + "-"
            let suffix = "." + rule.extension
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let uuidStart = name.index(name.startIndex, offsetBy: prefix.count)
            let uuidEnd = name.index(name.endIndex, offsetBy: -suffix.count)
            let text = String(name[uuidStart..<uuidEnd])
            guard text.utf8.count == 36,
                  let uuid = UUID(uuidString: text) else {
                continue
            }
            let canonical = uuid.uuidString
            guard text == canonical || text == canonical.lowercased() else { continue }
            return true
        }
        return false
    }

    private static func isPrivateOwnedDirectory(_ metadata: stat) -> Bool {
        metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == Darwin.geteuid()
            && metadata.st_mode & 0o077 == 0
    }

    private static func isEligibleScratchFile(_ metadata: stat, cutoff: TimeInterval) -> Bool {
        let modifiedAt = TimeInterval(metadata.st_mtimespec.tv_sec)
            + TimeInterval(metadata.st_mtimespec.tv_nsec) / 1_000_000_000
        return metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == Darwin.geteuid()
            && metadata.st_nlink == 1
            && modifiedAt.isFinite
            && modifiedAt <= cutoff
    }

    private static func directoryStillMatches(
        _ outputRoot: URL,
        descriptor: Int32,
        expected: ScratchIdentity
    ) -> Bool {
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              isPrivateOwnedDirectory(opened),
              ScratchIdentity(opened) == expected else { return false }

        var named = stat()
        let status = outputRoot.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &named)
        }
        return status == 0
            && isPrivateOwnedDirectory(named)
            && ScratchIdentity(named) == expected
    }

    private static func directoryEntryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        var value = entry.pointee
        return withUnsafeBytes(of: &value.d_name) { bytes in
            guard let base = bytes.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }
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
        timeout: TimeInterval,
        forceKillAfterTermination: TimeInterval = 1,
        waitForCleanupOnStop: Bool = false
    ) async -> RawOutcome {
        let outputRoot = execution.outputRoot
        _ = await Task.detached(priority: .utility) {
            cleanupStaleScratchFiles(in: outputRoot)
        }.value

        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/scree.py",
            name: "scree"
        ) else {
            return .failure("봉인한 scree 스크립트를 확인하지 못해 실행하지 않았습니다.")
        }
        guard let python3 = Self.python3Path(
            signedBundleURL: execution.signedBundleURL
        ) else {
            return .failure("봉인된 로컬 대화 엔진을 찾지 못해 scree를 실행하지 않았습니다.")
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
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument] + arguments,
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            timeout: timeout,
            forceKillAfterTermination: forceKillAfterTermination,
            waitForCleanupOnStop: waitForCleanupOnStop
        )
        guard result.endState != .timedOut else {
            return .timedOut
        }
        guard result.status == 0, result.endState == .exited else {
            if arguments.first?.hasPrefix("backup") == true,
               let data = result.output.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = payload["error"] as? String {
                return .failure("백업 작업을 중단했습니다: \(message)")
            }
            return .failure("scree 실행이 실패했습니다 (status \(result.status)).")
        }
        return .success(result.output)
    }

    /// A signed app may run only its nested, code-signed interpreter. System
    /// Python remains a development/test fallback for an unpackaged checkout;
    /// a damaged release never silently crosses that trust boundary.
    static func python3Path(
        signedBundleURL: URL?,
        developmentCandidates: [String] = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
    ) -> String? {
        if let signedBundleURL {
            let bundled = signedBundleURL
                .appendingPathComponent("Contents/Resources/modore-python/bin/python3.11")
                .path
            return isExecutableRegularFileWithoutFollowingLinks(bundled) ? bundled : nil
        }
        return developmentCandidates.first(where: isExecutableRegularFileWithoutFollowingLinks)
    }

    private static func isExecutableRegularFileWithoutFollowingLinks(_ path: String) -> Bool {
        var value = stat()
        let status = path.withCString { Darwin.lstat($0, &value) }
        return status == 0
            && value.st_mode & S_IFMT == S_IFREG
            && Darwin.access(path, X_OK) == 0
    }
}

extension ScanModel {
    func startSessionExport(
        tool: String,
        source: String,
        completion: @escaping (ScreePreserveOutcome) -> Void
    ) {
        let root = projectRoot
        startSessionExport(
            source: source,
            using: {
                await ScreeService.preserve(
                    projectRoot: root,
                    tool: tool,
                    source: source
                )
            },
            completion: completion
        )
    }

    /// Injection point for the same single-owner and termination contract
    /// exercised by the raw backup task.
    func startSessionExport(
        source: String,
        using run: @escaping () async -> ScreePreserveOutcome,
        completion: @escaping (ScreePreserveOutcome) -> Void
    ) {
        guard !applicationTerminationStarted else {
            completion(.failure("앱이 종료 중이어서 새 내보내기를 시작하지 않았습니다."))
            return
        }
        guard sessionExportTask == nil else {
            completion(.failure("다른 대화 내보내기가 진행 중입니다."))
            return
        }
        sessionExportGeneration += 1
        let generation = sessionExportGeneration
        screePreserveInFlightSource = source
        sessionExportTask = Task { [weak self] in
            guard let self else { return }
            let outcome = await run()
            guard !Task.isCancelled, generation == sessionExportGeneration else { return }
            sessionExportTask = nil
            screePreserveInFlightSource = nil
            completion(outcome)
        }
    }

    func startSessionBackup(
        operation: SessionBackupOperation,
        completion: @escaping (Result<SessionBackupReceipt, ScreeInspectionError>) -> Void
    ) {
        let root = projectRoot
        startSessionBackup(
            using: { await ScreeService.sessionBackup(projectRoot: root, operation: operation) },
            completion: completion
        )
    }

    /// Internal loader injection makes the termination lease testable without
    /// selecting a real raw archive. Only one raw operation may own the lease.
    func startSessionBackup(
        using run: @escaping () async -> Result<SessionBackupReceipt, ScreeInspectionError>,
        completion: @escaping (Result<SessionBackupReceipt, ScreeInspectionError>) -> Void
    ) {
        guard !applicationTerminationStarted else {
            completion(.failure(.init(message: "앱이 종료 중이어서 새 백업·복원 작업을 시작하지 않았습니다.")))
            return
        }
        guard sessionBackupTask == nil else {
            completion(.failure(.init(message: "다른 세션 백업·복원 작업이 진행 중입니다.")))
            return
        }
        sessionBackupGeneration += 1
        let generation = sessionBackupGeneration
        sessionBackupTask = Task {
            let result = await run()
            guard !Task.isCancelled, generation == sessionBackupGeneration else { return }
            sessionBackupTask = nil
            completion(result)
        }
    }

    /// Cancels every automatic Work loader plus any raw session transfer, then
    /// retains their task handles until cleanup finishes. The longer deadline
    /// applies only to raw backup/restore, whose Python SIGTERM handler may need
    /// time to remove a large partial ZIP or restore tree safely.
    @discardableResult
    func cancelApplicationTasksForTermination(
        completion: @escaping () -> Void
    ) -> Bool {
        applicationTerminationStarted = true
        var tasks = cancelWorkScreenTaskHandles()
        tasks.append(contentsOf: cancelStorageEvidenceTaskHandles())
        tasks.append(contentsOf: cancelNonDestructiveApplicationTaskHandles())
        tasks.append(contentsOf: takePendingDrainTasksForTermination())
        let hadRawTransfer = sessionBackupTask != nil
        if let sessionBackupTask {
            tasks.append(sessionBackupTask)
        }
        sessionBackupGeneration += 1
        sessionBackupTask?.cancel()
        sessionBackupTask = nil

        if let sessionExportTask {
            tasks.append(sessionExportTask)
        }
        sessionExportGeneration += 1
        sessionExportTask?.cancel()
        sessionExportTask = nil
        screePreserveInFlightSource = nil

        guard !tasks.isEmpty else { return false }
        applicationTerminationWaitGeneration += 1
        let generation = applicationTerminationWaitGeneration
        applicationTerminationWaitTask?.cancel()
        applicationTerminationDeadlineTask?.cancel()

        applicationTerminationWaitTask = Task {
            for task in tasks { await task.value }
            guard !Task.isCancelled else { return }
            finishApplicationTaskTerminationWait(
                generation: generation,
                completion: completion
            )
        }
        let deadline: UInt64 = hadRawTransfer ? 70_000_000_000 : 8_000_000_000
        applicationTerminationDeadlineTask = Task {
            do {
                try await Task.sleep(nanoseconds: deadline)
            } catch {
                return
            }
            finishApplicationTaskTerminationWait(
                generation: generation,
                completion: completion
            )
        }
        return true
    }

    private func finishApplicationTaskTerminationWait(
        generation: Int,
        completion: @escaping () -> Void
    ) {
        guard generation == applicationTerminationWaitGeneration else { return }
        applicationTerminationWaitGeneration += 1
        applicationTerminationWaitTask?.cancel()
        applicationTerminationDeadlineTask?.cancel()
        applicationTerminationWaitTask = nil
        applicationTerminationDeadlineTask = nil
        completion()
    }

    func refreshScreeReport() {
        let root = projectRoot
        refreshScreeReport {
            await ScreeService.run(projectRoot: root)
        }
    }

    /// Internal loader injection keeps the newest-request rule testable
    /// without launching the bundled Python runtime. Production always uses
    /// the zero-argument entry point above.
    func refreshScreeReport(
        using load: @escaping () async -> ScreeOutcome
    ) {
        guard !applicationTerminationStarted else { return }
        cancelAndRetainForDrain(screeTask)
        screeGeneration += 1
        let generation = screeGeneration
        screeNeedsRefresh = true
        screeLoading = true
        screeError = nil
        screeTask = Task {
            let outcome = await load()
            guard !Task.isCancelled, generation == screeGeneration else { return }
            switch outcome {
            case .success(let report):
                // Every repository judgment and continuity binding belongs to
                // the lineage in one specific audit report. A successful
                // re-audit invalidates that entire derived layer before the
                // new report becomes visible; WorkPage's revision task starts
                // a fresh binding pass for the new lineage.
                cancelAndRetainForDrain(archiveTask)
                archiveGeneration += 1
                archiveTask = nil
                archiveLoading = false
                archiveBindingComplete = false
                archiveError = nil
                repoAssessments = nil
                repoScanFailures.removeAll()
                reposNotScanned.removeAll()
                archiveInspectionFailures = 0
                retirementReview = nil
                screeReport = report
                screeReportRevision += 1
            case .failure(let message):
                screeError = message
            }
            guard generation == screeGeneration else { return }
            screeNeedsRefresh = false
            screeLoading = false
            screeTask = nil
        }
    }

    func preserveScreeSession(_ session: ScreeExpiringSession) {
        guard sessionExportTask == nil else { return }
        errorMessage = nil
        let tool = session.tool
        let source = session.source
        startSessionExport(tool: tool, source: source) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appendLog("대화 텍스트 내보내기: \(url.lastPathComponent)")
                AccessibilityAnnouncer.announce("대화 텍스트를 내보냈습니다")
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    /// Searches prior storage-related evidence only after the person submits
    /// a phrase. The newest request wins, matching conversation search: a
    /// slow earlier scan must not land beneath a question typed afterwards.
    func runStorageEvidenceSearch() {
        guard !applicationTerminationStarted else { return }
        let query = storageEvidenceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        cancelAndRetainForDrain(storageEvidenceTask)
        storageEvidenceGeneration += 1
        let generation = storageEvidenceGeneration
        storageEvidenceRunning = true
        storageEvidenceError = nil
        let root = projectRoot
        storageEvidenceTask = Task {
            defer {
                if generation == storageEvidenceGeneration { storageEvidenceRunning = false }
            }
            guard let execution = await Task.detached(priority: .userInitiated, operation: {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }).value else {
                if generation == storageEvidenceGeneration {
                    storageEvidenceError = "서명된 실행 런타임을 확인하지 못했습니다."
                }
                return
            }
            let outcome = await ScreeService.evidence(execution: execution, query: query)
            guard !Task.isCancelled, generation == storageEvidenceGeneration else { return }
            switch outcome {
            case .success(let result):
                storageEvidence = result
            case .failure(let error):
                storageEvidenceError = error.message
            }
        }
    }

    /// Stops the explicit storage-history search when its owning page leaves
    /// or the application terminates. The previous completed result remains
    /// visible; only the in-flight disk read is cancelled.
    func cancelStorageEvidenceSearch() {
        retainPendingDrainTasks(cancelStorageEvidenceTaskHandles())
    }

    func cancelStorageEvidenceTaskHandles() -> [Task<Void, Never>] {
        let tasks = [storageEvidenceTask].compactMap { $0 }
        storageEvidenceGeneration += 1
        storageEvidenceTask?.cancel()
        storageEvidenceTask = nil
        storageEvidenceRunning = false
        return tasks
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
        guard sessionExportTask == nil else { return }
        let source = binding.source.path
        errorMessage = nil
        // Every provider's own label. A binary Claude-or-Codex choice
        // filed Gemini exports under "Codex", which is wrong in the one
        // place a user later goes looking for them.
        let tool = binding.provider.displayName
        startSessionExport(tool: tool, source: source) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let url):
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appendLog("대화 텍스트 내보내기: \(url.lastPathComponent)")
                AccessibilityAnnouncer.announce("대화 텍스트를 내보냈습니다")
            case .failure(let message):
                errorMessage = message
            }
        }
    }
}
