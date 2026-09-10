import Foundation

@MainActor
final class EnvironmentRetirementService: ObservableObject {
    @Published var plan: EnvironmentPlan?
    @Published var busy = false
    @Published var executing = false
    @Published var error = ""

    static func invoke(root: URL, request: [String: Any]) async throws -> Data {
        EnvironmentFolderAccess.restore()
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value,
        let invocation = execution.pinnedInvocation(relativePath: "scripts/environment_retirement.py", name: "environment"),
        let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            throw RetirementError("환경 정리 실행 파일을 준비하지 못했습니다.")
        }
        var pinned = invocation.files
        pinned["request"] = try JSONSerialization.data(withJSONObject: request)
        let wrapper = "import sys; source=open(sys.argv[1],'rb').read(); sys.argv=['environment_retirement.py']+sys.argv[2:]; exec(compile(source,'environment_retirement.py','exec'),{'__name__':'__main__'})"
        let result = await LocalProcessRunner.capture(executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument, "--request-file", "@pch-pinned:request"],
            currentDirectory: execution.runtimeRoot, expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL, pinnedFiles: pinned, timeout: 3600,
            maxOutputBytes: 8_000_000, waitForCleanupOnStop: true)
        let data = Data(result.output.utf8)
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let error = object["error"] as? String {
            throw RetirementError(error)
        }
        guard result.succeeded, !result.outputTruncated else { throw RetirementError("응답 미확인 · 이전 기록을 불러와 이어서 확인하세요.") }
        return data
    }
    func perform(_ request: [String: Any], model: ScanModel, mutation: Bool = false) async {
        guard !busy, !model.cleanupInFlight, !model.applicationTerminationStarted else { return }
        busy = true; executing = mutation; error = ""
        if mutation { model.cleanupInFlight = true; model.beginDestructiveCleanupTransaction() }
        defer {
            busy = false; executing = false
            if mutation { model.cleanupInFlight = false; model.finishDestructiveCleanupTransaction() }
        }
        do {
            let data = try await Self.invoke(root: model.projectRoot, request: request)
            plan = try JSONDecoder().decode(EnvironmentPlan.self, from: data)
        } catch { self.error = error.localizedDescription }
    }
    func approveAndRun(ids: [String], model: ScanModel) async {
        guard let plan else { return }
        await perform(["action":"approve", "id":plan.id, "ids":ids], model:model)
        guard error.isEmpty else { return }
        await perform(["action":"execute", "id":plan.id, "ids":ids], model:model, mutation:true)
        // APFS deletion is asynchronous. A later observation never repeats mutation.
        guard error.isEmpty else { return }
        do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
        await perform(["action":"remeasure", "id":plan.id], model:model)
    }
    func cancel() {
        guard let id = plan?.id, UUID(uuidString:id) != nil else { return }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Modore/environment-retirement")
        do { try Data().write(to:root.appendingPathComponent("cancel-"+id), options:.atomic) }
        catch { self.error = error.localizedDescription }
    }
}
