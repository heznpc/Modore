import Foundation

/// One verified cleanup runtime shared by both the single-recipe approval flow
/// and a recovery plan. The shell harness still owns every destructive safety
/// boundary: this type only pins the signed inputs and transports its protocol.
struct CleanupExecutionContext: Sendable {
    let execution: RuntimeExecutionContext
    let invocationArgument: String
    let pinnedFiles: [String: Data]
    let environment: [String: String]
}

struct CleanupInvocation: Equatable, Sendable {
    let pinnedFiles: [String: Data]
    let arguments: [String]
}

struct CleanupExecutionClient: Sendable {
    let prepare: @Sendable (URL) async -> CleanupExecutionContext?
    let preview: @Sendable (
        String,
        CleanupExecutionRequest?,
        CleanupExecutionContext
    ) async -> CapturedProcessResult
    let execute: @Sendable (
        CleanupPreview,
        CleanupExecutionRequest?,
        CleanupExecutionContext
    ) async -> CapturedProcessResult?

    static let live = CleanupExecutionClient(
        prepare: { await CleanupExecutionService.prepare(projectRoot: $0) },
        preview: { recipeID, request, context in
            await CleanupExecutionService.preview(
                recipeID: recipeID,
                request: request,
                using: context
            )
        },
        execute: { preview, request, context in
            await CleanupExecutionService.execute(
                preview,
                request: request,
                using: context
            )
        }
    )
}

enum CleanupExecutionService {
    static let previewTimeout: TimeInterval = 60
    static let executionTimeout: TimeInterval = 15 * 60
    static let stagingRecoveryDisplayPath = "~/Library/Application Support/Modore/cleanup-staging"

    static func prepare(projectRoot: URL) async -> CleanupExecutionContext? {
        let execution = await Task.detached(priority: .userInitiated) {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }.value
        guard let execution,
              let invocation = execution.pinnedInvocation(
                relativePath: "scripts/cleanup.sh",
                name: "cleanup"
              ),
              let supportModule = execution.pinnedSupportDirectoryModule(),
              let tokenModule = execution.pinnedApprovalTokenModule() else {
            return nil
        }
        return CleanupExecutionContext(
            execution: execution,
            invocationArgument: invocation.argument,
            pinnedFiles: invocation.files
                .merging(supportModule.files) { current, _ in current }
                .merging(tokenModule.files) { current, _ in current },
            environment: supportModule.environment
                .merging(tokenModule.environment) { current, _ in current }
        )
    }

    static func preview(
        recipeID: String,
        request: CleanupExecutionRequest? = nil,
        using context: CleanupExecutionContext
    ) async -> CapturedProcessResult {
        guard let invocation = previewInvocation(
            recipeID: recipeID,
            request: request,
            pinnedFiles: context.pinnedFiles
        ) else {
            return invalidInvocationResult()
        }
        return await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [context.invocationArgument, "--preview", recipeID] + invocation.arguments,
            currentDirectory: context.execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: context.execution.runtimeRootIdentity,
            expectedSignedBundleURL: context.execution.signedBundleURL,
            pinnedFiles: invocation.pinnedFiles,
            environment: context.environment,
            timeout: previewTimeout,
            maxOutputBytes: 256_000
        )
    }

    static func validatedPreview(_ result: CapturedProcessResult, recipeID: String) -> CleanupPreview? {
        guard result.succeeded,
              let preview = CleanupPreview(protocolText: result.output),
              preview.operation == "preview", preview.recipeID == recipeID else { return nil }
        return preview
    }

    /// Log only allowlisted stages and process metadata, never raw output:
    /// the protocol also carries an approval capability and private paths.
    static func previewDiagnostic(_ result: CapturedProcessResult, elapsed: TimeInterval) -> String {
        let phases = [
            "runtime-setup": "런타임 준비",
            "request-validation": "요청 검증",
            "target-validation": "대상 검증",
            "process-check": "사용 프로세스 확인",
            "manifest-measurement": "승인 근거·크기 측정",
            "complete": "응답 완료",
        ]
        var phase = "단계 미확인"
        for line in result.output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2, parts[0] == "previewPhase", let known = phases[String(parts[1])] {
                phase = known
            }
        }
        let end: String
        switch result.endState {
        case .exited: end = "프로세스 종료"
        case .timedOut: end = "시간 초과"
        case .cancelled: end = "취소"
        case .outputLimit: end = "출력 상한 초과"
        case .launchFailed: end = "실행 시작 실패"
        }
        let duration = elapsed.isFinite ? String(format: "%.1f", max(0, elapsed)) : "?"
        return "\(duration)초 · \(phase) · \(end)(\(result.status))"
            + (result.outputTruncated ? " · 출력 잘림" : "")
    }

    static func execute(
        _ preview: CleanupPreview,
        request: CleanupExecutionRequest? = nil,
        using context: CleanupExecutionContext
    ) async -> CapturedProcessResult? {
        guard let invocation = executionInvocation(
            preview: preview,
            request: request,
            pinnedFiles: context.pinnedFiles
        ) else {
            return nil
        }
        return await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [
                context.invocationArgument, "--execute", preview.recipeID,
            ] + invocation.arguments,
            currentDirectory: context.execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: context.execution.runtimeRootIdentity,
            expectedSignedBundleURL: context.execution.signedBundleURL,
            pinnedFiles: invocation.pinnedFiles,
            environment: context.environment,
            timeout: executionTimeout,
            maxOutputBytes: 512_000
        )
    }

    static func previewInvocation(
        recipeID: String,
        request: CleanupExecutionRequest?,
        pinnedFiles: [String: Data]
    ) -> CleanupInvocation? {
        guard pinnedFiles["cleanup_request"] == nil else { return nil }
        guard let request else {
            return CleanupExecutionRequest.isRequired(for: recipeID)
                ? nil
                : CleanupInvocation(pinnedFiles: pinnedFiles, arguments: [])
        }
        guard request.recipeID == recipeID else { return nil }
        var requestFiles = pinnedFiles
        requestFiles["cleanup_request"] = request.protocolData
        return CleanupInvocation(
            pinnedFiles: requestFiles,
            arguments: ["--request-file", "@pch-pinned:cleanup_request"]
        )
    }

    static func executionInvocation(
        preview: CleanupPreview,
        request: CleanupExecutionRequest?,
        pinnedFiles: [String: Data]
    ) -> CleanupInvocation? {
        guard preview.canExecute,
              var invocation = previewInvocation(
                recipeID: preview.recipeID,
                request: request,
                pinnedFiles: pinnedFiles
              ),
              invocation.pinnedFiles["approval_token"] == nil else {
            return nil
        }
        invocation = CleanupInvocation(
            pinnedFiles: invocation.pinnedFiles.merging([
                "approval_token": Data(preview.approvalToken.utf8)
            ]) { current, _ in current },
            arguments: [
                "--owner-approved",
                "--approval-token-file", "@pch-pinned:approval_token",
            ] + invocation.arguments
        )
        return invocation
    }

    private static func invalidInvocationResult() -> CapturedProcessResult {
        CapturedProcessResult(
            status: 64,
            output: "",
            endState: .launchFailed,
            outputTruncated: false
        )
    }
}
