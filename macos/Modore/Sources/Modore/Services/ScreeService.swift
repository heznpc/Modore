import Foundation

/// Runs the sealed `scree.py` and parses its report. Read-only: this never
/// deletes anything and never retains session content — scree's own contract
/// already guarantees that; this layer only decodes the JSON it prints.
enum ScreeOutcome {
    case success(ScreeReport)
    case failure(String)
}

enum ScreeService {
    static func run(projectRoot: URL) async -> ScreeOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure("서명된 실행 런타임을 확인하지 못해 scree를 실행하지 않았습니다.")
        }
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
            arguments: ["-c", wrapper, invocation.argument, "report", "--json"],
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            timeout: 180
        )
        guard result.endState != .timedOut else {
            return .failure("scree가 3분 안에 끝나지 않았습니다. 세션·워크트리가 많으면 시간이 더 걸릴 수 있습니다.")
        }
        guard result.status == 0, result.endState == .exited else {
            return .failure("scree 실행이 실패했습니다 (status \(result.status)).")
        }
        guard let start = result.output.firstIndex(of: "{") else {
            return .failure("scree 출력에서 JSON을 찾지 못했습니다.")
        }
        let jsonSlice = result.output[start...]
        guard let data = jsonSlice.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let report = ScreeReport(json: object) else {
            return .failure("scree 출력을 해석하지 못했습니다.")
        }
        return .success(report)
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
}
