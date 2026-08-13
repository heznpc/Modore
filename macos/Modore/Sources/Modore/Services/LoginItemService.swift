import AppKit
import Foundation

/// Runs the sealed `scripts/login_items.sh` -- the first Modore action that
/// targets a named macOS setting instead of a file path (see the script's
/// own header comment for why cleanup.sh's file-oriented machinery doesn't
/// fit and only its approval-token pattern was reused). Preview is
/// read-only; execute requires an approval token from a prior preview and
/// re-verifies the removal actually took effect before reporting success.
enum LoginItemPreviewOutcome: Equatable {
    case ready(name: String, approvalToken: String)
    case notFound(name: String)
    case failure(String)
}

enum LoginItemExecuteOutcome: Equatable {
    case ok(name: String)
    case alreadyGone(name: String)
    case failure(String, name: String)
}

enum LoginItemService {
    /// Pure and independently testable: what a preview's protocol output
    /// means, given the exact same key-value shape login_items.sh emits.
    static func mapPreviewOutcome(_ values: [String: String], requestedName: String) -> LoginItemPreviewOutcome {
        let reportedName = values["name"] ?? requestedName
        switch values["status"] {
        case "ready":
            guard let token = values["approvalToken"], token.count == 64 else {
                return .failure("승인 토큰을 확인하지 못했습니다.")
            }
            return .ready(name: reportedName, approvalToken: token)
        case "not_found":
            return .notFound(name: reportedName)
        default:
            return .failure("로그인 항목을 미리 확인하지 못했습니다.")
        }
    }

    /// Pure and independently testable: same idea as mapPreviewOutcome, for
    /// execute's protocol output.
    static func mapExecuteOutcome(_ values: [String: String], requestedName: String) -> LoginItemExecuteOutcome {
        let reportedName = values["name"] ?? requestedName
        switch values["status"] {
        case "ok":
            return .ok(name: reportedName)
        case "already_gone":
            return .alreadyGone(name: reportedName)
        default:
            return .failure("로그인 항목을 제거하지 못했습니다.", name: reportedName)
        }
    }

    static func preview(projectRoot: URL, name: String) async -> LoginItemPreviewOutcome {
        switch await invoke(projectRoot: projectRoot, arguments: ["--preview", name], pinnedFiles: [:]) {
        case .failure(let message):
            return .failure(message)
        case .success(let output):
            return mapPreviewOutcome(StorageWatchService.protocolValues(output), requestedName: name)
        }
    }

    static func execute(projectRoot: URL, name: String, approvalToken: String) async -> LoginItemExecuteOutcome {
        switch await invoke(
            projectRoot: projectRoot,
            arguments: [
                "--execute", name, "--owner-approved",
                "--approval-token-file", "@pch-pinned:approval_token",
            ],
            pinnedFiles: ["approval_token": Data(approvalToken.utf8)]
        ) {
        case .failure(let message):
            return .failure(message, name: name)
        case .success(let output):
            return mapExecuteOutcome(StorageWatchService.protocolValues(output), requestedName: name)
        }
    }

    private enum RawOutcome {
        case success(String)
        case failure(String)
    }

    private static func invoke(
        projectRoot: URL,
        arguments: [String],
        pinnedFiles: [String: Data]
    ) async -> RawOutcome {
        guard let execution = await Task.detached(priority: .userInitiated, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: projectRoot)
        }).value else {
            return .failure("서명된 실행 런타임을 확인하지 못해 실행하지 않았습니다.")
        }
        guard let invocation = execution.pinnedInvocation(
            relativePath: "scripts/login_items.sh",
            name: "login_items"
        ), let supportModule = execution.pinnedSupportDirectoryModule(),
           let tokenModule = execution.pinnedApprovalTokenModule() else {
            return .failure("봉인한 로그인 항목 스크립트를 확인하지 못해 실행하지 않았습니다.")
        }
        var files = invocation.files
            .merging(supportModule.files) { current, _ in current }
            .merging(tokenModule.files) { current, _ in current }
        for (key, value) in pinnedFiles {
            // The module dictionaries merge keep-first, but a raw value used
            // to land with an unconditional overwrite -- the exact asymmetry
            // that made the "approval_token" vs "approval_token_module" key
            // collision possible to reintroduce silently. A colliding key now
            // refuses instead of clobbering whichever payload merged first.
            guard files[key] == nil else {
                return .failure("내부 오류: 고정 파일 키가 충돌해 실행하지 않았습니다 (\(key)).")
            }
            files[key] = value
        }
        let result = await LocalProcessRunner.capture(
            executable: "/bin/bash",
            arguments: [invocation.argument] + arguments,
            currentDirectory: execution.runtimeRoot,
            expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL,
            pinnedFiles: files,
            environment: supportModule.environment.merging(tokenModule.environment) { current, _ in current },
            timeout: 30
        )
        // login_items.sh's own contract: 0 for a completed action, 1 for an
        // expected, protocol-documented outcome (not_found/blocked/expired/
        // mismatch/failed) -- both still emit a real status line to parse.
        // Anything else means the invocation itself never ran cleanly.
        guard result.status == 0 || result.status == 1, result.endState == .exited else {
            return .failure("로그인 항목 스크립트 실행이 실패했습니다 (status \(result.status)).")
        }
        return .success(result.output)
    }
}

extension ScanModel {
    // `isBusy` as well as the per-action flag: the Security page stays
    // interactive during a scan, and confirming a removal kicks off its own
    // rescan. Without this a right-click removal mid-scan started a second
    // ScanPipeline writing the same scan_result.json/report files as the
    // first, with two finishRun()s racing over whichever mix survived --
    // and the second run isn't held in `scanTask`, so 검사 취소 could not
    // stop it. prepareCleanup already guards this way.
    func previewLoginItemRemoval(_ name: String) {
        guard !isBusy, loginItemActionInFlight == nil else { return }
        loginItemActionInFlight = name
        errorMessage = nil
        let root = projectRoot
        Task {
            defer { loginItemActionInFlight = nil }
            switch await LoginItemService.preview(projectRoot: root, name: name) {
            case .ready(let confirmedName, let token):
                pendingLoginItemRemoval = PendingLoginItemRemoval(name: confirmedName, approvalToken: token)
            case .notFound:
                errorMessage = "이 로그인 항목을 더 이상 찾을 수 없습니다. 목록을 새로고침하세요."
            case .failure(let message):
                errorMessage = message
            }
        }
    }

    func confirmLoginItemRemoval() {
        guard !isBusy, let pending = pendingLoginItemRemoval, loginItemActionInFlight == nil else { return }
        pendingLoginItemRemoval = nil
        loginItemActionInFlight = pending.name
        let root = projectRoot
        Task {
            defer { loginItemActionInFlight = nil }
            switch await LoginItemService.execute(projectRoot: root, name: pending.name, approvalToken: pending.approvalToken) {
            case .ok(let name), .alreadyGone(let name):
                appendLog("로그인 항목 제거: \(name)")
                AccessibilityAnnouncer.announce("로그인 항목을 제거했습니다")
                state = .running
                let ok = await ScanPipeline.run(projectRoot: root) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
                await finishRun(success: ok)
            case .failure(let message, _):
                errorMessage = message
            }
        }
    }

    func cancelLoginItemRemoval() {
        guard loginItemActionInFlight == nil else { return }
        pendingLoginItemRemoval = nil
    }
}
