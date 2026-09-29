import Foundation
@MainActor
final class WorkResourceService: ObservableObject {
    @Published var snapshot: WorkResourceSnapshot?
    @Published var busy = false
    @Published var message = ""
    func invoke(root: URL, request: [String: Any]) async throws -> Data {
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value,
        let invocation = execution.pinnedInvocation(relativePath: "scripts/work_resources.py", name: "resources"),
        let guardInvocation = execution.pinnedInvocation(relativePath: "scripts/tool_reuse.py", name: "tool_reuse"),
        let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            throw RetirementError(L10n.text("작업 자원 런타임을 준비하지 못했습니다."))
        }
        var pinned = invocation.files
        pinned.merge(guardInvocation.files) { current, _ in current }
        pinned["request"] = try JSONSerialization.data(withJSONObject: request)
        let wrapper = """
        import sys, types, hashlib
        source = open(sys.argv[1], 'rb').read()
        guard_source = open(sys.argv[2], 'rb').read()
        adapter = types.ModuleType('tool_reuse')
        adapter.__dict__.update(__file__='tool_reuse.py', _ADAPTER_SHA256=hashlib.sha256(guard_source).hexdigest())
        exec(compile(guard_source, 'tool_reuse.py', 'exec'), adapter.__dict__)
        sys.argv = ['work_resources.py'] + sys.argv[3:]
        exec(compile(source, 'work_resources.py', 'exec'), {'__name__':'__main__', '__file__':'scripts/work_resources.py', 'tool_reuse':adapter})
        """
        let result = await LocalProcessRunner.capture(executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument, guardInvocation.argument, "--request-file", "@pch-pinned:request"],
            currentDirectory: execution.runtimeRoot, expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL, pinnedFiles: pinned, timeout: 90,
            maxOutputBytes: 8_000_000, waitForCleanupOnStop: true)
        let data = Data(result.output.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let error = object?["error"] as? String { throw RetirementError(error) }
        guard result.succeeded else { throw RetirementError(L10n.format("자원 조회·실행 응답 미확인: %@ · %@", String(describing: result.status), String(describing: result.output.prefix(500)))) }
        return data
    }
    func refresh(root: URL) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { snapshot = try JSONDecoder().decode(WorkResourceSnapshot.self, from: await invoke(root: root, request: ["action": "status"])) }
        catch { message = error.localizedDescription }
    }
    func act(model: ScanModel, request: [String: Any]) async {
        guard !busy, !model.cleanupInFlight, !model.applicationTerminationStarted else { return }
        busy = true
        model.cleanupInFlight = true; model.beginDestructiveCleanupTransaction()
        defer { busy = false; model.cleanupInFlight = false; model.finishDestructiveCleanupTransaction() }
        do {
            let data = try await invoke(root: model.projectRoot, request: request)
            let object = (try JSONSerialization.jsonObject(with: data)) as? [String: Any]
            message = (object?["message"] as? String ?? L10n.text("사용 연결 등록됨")) + (object?["receipt"].map { "\n\($0)" } ?? "")
            model.appendLog(L10n.format("작업 자원: %@", String(describing: message)))
            snapshot = try JSONDecoder().decode(WorkResourceSnapshot.self, from: await invoke(root: model.projectRoot, request: ["action": "status"]))
        } catch { message = error.localizedDescription }
    }
}
