import Foundation

enum SessionRecoveryService {
    static func run(projectRoot: URL, operation: SessionRecoveryOperation) async -> Result<SessionRecoveryResponse, SessionRecoveryFailure> {
        guard let execution = await RuntimeWorkspace.prepareExecutionAsync(projectRoot: projectRoot) else {
            return .failure(.init(message: L10n.text("서명된 실행 런타임을 확인하지 못했습니다.")))
        }
        return await run(execution: execution, operation: operation)
    }

    /// Fixture homes are injected only by internal tests, never inherited from
    /// the app environment or inferred from user-selected backup folders.
    static func run(execution: RuntimeExecutionContext, operation: SessionRecoveryOperation,
                    homeOverride: URL? = nil) async -> Result<SessionRecoveryResponse, SessionRecoveryFailure> {
        do {
            let result = try await invoke(execution: execution, script: "session_recovery.py",
                                          arguments: operation.arguments(homeOverride: homeOverride), timeout: operation.timeout)
            return try .success(decode(result, operation: operation))
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    static func invoke(execution: RuntimeExecutionContext, script: String,
                       arguments: [String], timeout: TimeInterval) async throws -> CapturedProcessResult {
        guard ["session_recovery.py", "session_resume.py", "backup_reclaim.py", "path_reconnect.py"].contains(script),
              let invocation = execution.pinnedInvocation(relativePath: "scripts/" + script, name: "session_recovery"),
              let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            throw SessionRecoveryFailure(message: L10n.text("백업·이전 실행 파일을 확인하지 못했습니다."))
        }
        let wrapper = """
        import sys
        source = open(sys.argv[1], "rb").read()
        name = sys.argv[2]
        sys.argv = [name] + sys.argv[3:]
        exec(compile(source, name, "exec"), {"__name__": "__main__", "__file__": name})
        """
        return await LocalProcessRunner.capture(
            executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument, script] + arguments,
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: invocation.files,
            timeout: timeout, maxOutputBytes: 8_000_000,
            forceKillAfterTermination: 60, waitForCleanupOnStop: true
        )
    }

    static func validatedData(_ result: CapturedProcessResult) throws -> Data {
        guard result.succeeded else {
            if result.endState == .cancelled {
                throw SessionRecoveryFailure(message: L10n.text("작업을 중단했습니다. 부분 결과를 성공으로 표시하지 않습니다."))
            }
            if result.endState == .timedOut {
                throw SessionRecoveryFailure(message: L10n.text("제한 시간 안에 검증을 마치지 못했습니다. 결과를 다시 확인하세요."))
            }
            if let data = result.output.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let message = object["error"] as? String {
                throw SessionRecoveryFailure(message: L10n.message(message))
            }
            throw SessionRecoveryFailure(message: L10n.text("백업·이전 결과를 확인하지 못했습니다. 성공으로 처리하지 않았습니다."))
        }
        return Data(result.output.utf8)
    }

    static func decode(_ result: CapturedProcessResult, operation: SessionRecoveryOperation) throws -> SessionRecoveryResponse {
        let data = try validatedData(result)
        if case .plan = operation {
            let plan = try JSONDecoder().decode(SessionRecoveryPlan.self, from: data)
            guard plan.isValid else { throw invalidResponse() }
            return .plan(plan)
        }
        let receipt = try JSONDecoder().decode(SessionRecoveryReceipt.self, from: data)
        guard operation.accepts(receipt) else { throw invalidResponse() }
        return .receipt(receipt)
    }

    private static func invalidResponse() -> SessionRecoveryFailure {
        .init(message: L10n.text("백업·이전 응답이 요청한 대상·검증 결과와 일치하지 않습니다."))
    }
}

enum SessionResumeService {
    static func list(projectRoot: URL, restoredRoot: URL) async -> Result<SessionResumeList, SessionRecoveryFailure> {
        await request(projectRoot: projectRoot, arguments: ["list", restoredRoot.path]) { data in
            let value = try JSONDecoder().decode(SessionResumeList.self, from: data)
            guard value.isValid else { throw invalidResponse() }
            return value
        }
    }

    static func prepare(projectRoot: URL, restoredRoot: URL, candidate: SessionResumeCandidate,
                        workspace: URL, providerHome: URL) async -> Result<SessionResumePlan, SessionRecoveryFailure> {
        await request(projectRoot: projectRoot, arguments: ["prepare", restoredRoot.path,
            "--provider", candidate.provider, "--session-id", candidate.sessionId,
            "--workspace", workspace.path, "--provider-home", providerHome.path]) { data in
            let value = try JSONDecoder().decode(SessionResumePlan.self, from: data)
            guard value.matches(candidate, workspace: workspace, home: providerHome) else { throw invalidResponse() }
            return value
        }
    }

    private static func request<Value>(projectRoot: URL, arguments: [String],
                                      decode: (Data) throws -> Value) async -> Result<Value, SessionRecoveryFailure> {
        guard let execution = await RuntimeWorkspace.prepareExecutionAsync(projectRoot: projectRoot) else {
            return .failure(.init(message: L10n.text("서명된 실행 런타임을 확인하지 못했습니다.")))
        }
        do {
            let result = try await SessionRecoveryService.invoke(execution: execution, script: "session_resume.py",
                arguments: arguments, timeout: 900)
            return .success(try decode(SessionRecoveryService.validatedData(result)))
        } catch {
            return .failure(.init(message: error.localizedDescription))
        }
    }

    private static func invalidResponse() -> SessionRecoveryFailure {
        .init(message: L10n.text("재개 준비 응답이 선택한 세션·작업 폴더와 일치하지 않습니다."))
    }
}

extension ScanModel {
    /// Share the existing raw-backup lease: termination already cancels and
    /// drains this task with enough time for the backend's exact-path cleanup.
    func startSessionRecovery(
        operation: SessionRecoveryOperation,
        completion: @escaping (Result<SessionRecoveryResponse, SessionRecoveryFailure>) -> Void
    ) {
        let root = projectRoot
        startSessionRecovery(using: { await SessionRecoveryService.run(projectRoot: root, operation: operation) }, completion: completion)
    }

    func startSessionRecovery<Value>(
        using run: @escaping () async -> Result<Value, SessionRecoveryFailure>,
        completion: @escaping (Result<Value, SessionRecoveryFailure>) -> Void
    ) {
        guard !applicationTerminationStarted, sessionBackupTask == nil else {
            completion(.failure(.init(message: L10n.text("다른 백업·복원 또는 앱 종료가 진행 중입니다."))))
            return
        }
        sessionBackupGeneration += 1
        let generation = sessionBackupGeneration
        sessionBackupTask = Task {
            let result = await run()
            guard generation == sessionBackupGeneration else { return }
            sessionBackupTask = nil
            completion(Task.isCancelled
                ? .failure(.init(message: L10n.text("작업을 중단했습니다. 부분 결과를 성공으로 표시하지 않습니다.")))
                : result)
        }
    }

    func cancelSessionRecovery() {
        // Keep the lease until the subprocess has finished its cleanup.
        sessionBackupTask?.cancel()
    }
}
