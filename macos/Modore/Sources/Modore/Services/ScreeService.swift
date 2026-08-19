import AppKit
import Foundation
import MothballCore

/// Runs the sealed `scree.py` and parses its report. Read-only: this never
/// deletes anything and never retains session content — scree's own contract
/// already guarantees that; this layer only decodes the JSON it prints.
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
            if case .notAssessed = assessment {
                // A shallow pass that found nothing has not failed -- it
                // has reached the limit of what matching recorded working
                // directories can tell you. Sessions run from a parent
                // directory record their cwd there, so the workspaces that
                // look emptiest under a shallow pass are exactly the ones
                // whose bindings only a content scan can see. Escalate
                // that one repo rather than reporting an absence nobody
                // established, or running the expensive pass over every
                // candidate that already answered.
                if Self.reportedNothingWithinShallowLimits(data) {
                    guard !deep else {
                        // Already the deepest pass available and it still
                        // stopped early. Nothing was established, and
                        // saying so beats reporting a parse failure that
                        // did not happen -- the user can act on "the scan
                        // was cut short", not on "unreadable output".
                        return .failed("세션 검사가 끝까지 진행되지 않아 연결 여부를 확정하지 못했습니다.")
                    }
                    return await bind(execution: execution, workspace: workspace,
                                      repoURL: repoURL, deep: true,
                                      homeOverride: homeOverride)
                }
                // Otherwise the binder printed JSON this build could not
                // read as a completed assessment -- schema drift between
                // the two languages, not a repo with unknown sessions.
                return .failed("세션 바인더 출력을 해석하지 못했습니다.")
            }
            return ScreeBindOutcome(assessment: assessment, diagnostic: nil)
        }
    }

    /// True when the payload is a well-formed shallow run that found
    /// nothing — the one `notAssessed` worth spending a deep pass on.
    static func reportedNothingWithinShallowLimits(_ data: Data) -> Bool {
        guard let report = try? BindReport.decoder().decode(BindReport.self, from: data) else {
            return false
        }
        // A truncated run is worth retrying too -- it stopped early, so it
        // established nothing either. Only a completed one is final.
        return report.assessed && report.bindings.isEmpty && report.coverage != "complete"
    }
}

extension ScreeService {
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
        // scree's own fixed store labels, so the export filename matches
        // what the session page produces for the same file.
        let tool = binding.provider == .claude ? "Claude" : "Codex"
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
