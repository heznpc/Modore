import Foundation

/// Asset retirement owns its execution and receipts inside Modore.
/// This surface deliberately does not participate in Taxi's execution/audit.
@MainActor
enum AssetRetirementService {
    static func invoke(root: URL, request: [String: Any]) async throws -> AssetRetirementPlan {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value else {
            throw RetirementError("실행 런타임을 준비하지 못했습니다.")
        }
        return try await invoke(execution: execution, request: request)
    }

    static func invoke(execution: RuntimeExecutionContext, request: [String: Any]) async throws -> AssetRetirementPlan {
        let payload = try JSONSerialization.data(withJSONObject: request)
        guard let invocation = execution.pinnedInvocation(relativePath: "scripts/asset_retirement.py", name: "retirement"),
              let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            throw RetirementError("레포 정리 실행 파일을 확인하지 못했습니다.")
        }
        var pinned = invocation.files
        pinned["retirement_request"] = payload
        let wrapper = """
        import sys
        source = open(sys.argv[1], 'rb').read()
        sys.argv = ['asset_retirement.py'] + sys.argv[2:]
        exec(compile(source, 'asset_retirement.py', 'exec'), {'__name__': '__main__'})
        """
        let result = await LocalProcessRunner.capture(
            executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument, "@pch-pinned:retirement_request"],
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: pinned,
            timeout: 3600,
            maxOutputBytes: 16_000_000,
            waitForCleanupOnStop: true
        )
        let data = Data(result.output.utf8)
        if let failure = try? JSONDecoder().decode(RetirementFailure.self, from: data) {
            throw RetirementError(failure.error)
        }
        guard result.status == 0, !result.outputTruncated else {
            throw RetirementError("실행 응답을 확인하지 못했습니다. 이전 거래 불러오기로 결과를 확인하세요. (\(result.status))")
        }
        return try JSONDecoder().decode(AssetRetirementPlan.self, from: data)
    }

    static func resetCancellation(_ transaction: String) {
        guard UUID(uuidString: transaction) != nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Modore/asset-retirement")
            .appendingPathComponent(transaction + ".cancel")
        try? FileManager.default.removeItem(at: url)
    }

    static func cancel(_ transaction: String) throws {
        guard UUID(uuidString: transaction) != nil else { return }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Modore/asset-retirement")
            .appendingPathComponent(transaction + ".cancel")
        try Data().write(to: url)
    }
}

private struct RetirementFailure: Decodable { let error: String }
struct RetirementError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
