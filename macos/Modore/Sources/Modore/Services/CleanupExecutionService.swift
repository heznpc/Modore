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

enum CleanupExecutionService {
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
        guard let invocation = invocation(
            recipeID: recipeID,
            request: request,
            context: context
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
            timeout: 60,
            maxOutputBytes: 256_000
        )
    }

    static func execute(
        _ preview: CleanupPreview,
        request: CleanupExecutionRequest? = nil,
        using context: CleanupExecutionContext
    ) async -> CapturedProcessResult? {
        guard preview.canExecute,
              let invocation = invocation(
                recipeID: preview.recipeID,
                request: request,
                context: context
              ),
              invocation.pinnedFiles["approval_token"] == nil else {
            return nil
        }
        var pinnedFiles = invocation.pinnedFiles
        pinnedFiles["approval_token"] = Data(preview.approvalToken.utf8)
        return await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [
                context.invocationArgument, "--execute", preview.recipeID,
                "--owner-approved", "--approval-token-file", "@pch-pinned:approval_token",
            ] + invocation.arguments,
            currentDirectory: context.execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: context.execution.runtimeRootIdentity,
            expectedSignedBundleURL: context.execution.signedBundleURL,
            pinnedFiles: pinnedFiles,
            environment: context.environment,
            timeout: executionTimeout,
            maxOutputBytes: 512_000
        )
    }

    private static func invocation(
        recipeID: String,
        request: CleanupExecutionRequest?,
        context: CleanupExecutionContext
    ) -> (pinnedFiles: [String: Data], arguments: [String])? {
        guard context.pinnedFiles["cleanup_request"] == nil else { return nil }
        guard let request else {
            return recipeID == "project_residue"
                ? nil
                : (context.pinnedFiles, [])
        }
        guard request.recipeID == recipeID else { return nil }
        var pinnedFiles = context.pinnedFiles
        pinnedFiles["cleanup_request"] = request.protocolData
        return (
            pinnedFiles,
            ["--request-file", "@pch-pinned:cleanup_request"]
        )
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
