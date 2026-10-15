import Foundation

struct SkillInstallation: Decodable, Identifiable, Hashable {
    let id, name, description, host, source, origin, path, filePath, realPath, link: String
    let version, hash, fingerprint, discovery, session, error: String
    let exists, manageable: Bool
    let duplicates, variants: Int
}

struct SkillBackup: Decodable, Identifiable {
    let id, name, original, realPath, link, host, origin, state, error, backupPath: String
    let created: Double
    var stateTitle: String {
        switch state {
        case "disabled": return L10n.text("백업 완료 · 비활성화")
        case "restored": return L10n.text("복구 완료")
        case "failed": return L10n.text("실패 · 원본 이동 안 됨")
        case "preparing": return L10n.text("백업 준비 중단 · 확인 필요")
        case "backedUp": return L10n.text("백업 완료 · 이동 상태 확인 필요")
        default: return L10n.text("일부 진행 · 확인 필요")
        }
    }
}
struct SkillSnapshot: Decodable {
    let items: [SkillInstallation]
    let backups: [SkillBackup]
    let warnings: [String]
    let scope: String
    let observed: Double
}

enum SkillSourceFilter: String, CaseIterable, Identifiable {
    case all, personal, shared, system, plugin, reference
    var id: Self { self }
    static let referenceHost = "참고"

    private var source: String? {
        switch self {
        case .all: return nil
        case .personal: return "개인 설치"
        case .shared: return "공유 개인 설치"
        case .system: return "시스템 기본"
        case .plugin: return "플러그인 제공"
        case .reference: return "CLI 작업본"
        }
    }

    var title: String { source.map { L10n.message($0) } ?? L10n.text("전체") }
    func matches(_ installation: SkillInstallation) -> Bool {
        source == nil || source == installation.source
    }
}

@MainActor
final class SkillInventoryService: ObservableObject {
    @Published var snapshot: SkillSnapshot?
    @Published var busy = false
    @Published var error = ""
    @Published var diff = ""
    @Published private(set) var demo = false
    typealias Operation = @MainActor (URL, [String: Any], Bool) async throws -> Data
    private let operation: Operation?

    init(operation: Operation? = nil) {
        self.operation = operation
    }

    /// Register reads with the app's termination owner so Python and an optional
    /// Codex discovery server are cancelled and drained before Cmd-Q completes.
    func startRead(_ request: [String: Any], model: ScanModel,
                   completion: @escaping @MainActor () -> Void = {}) {
        guard ["status", "probe", "compare"].contains(request["action"] as? String ?? "") else { return }
        model.startTrackedApplicationTask {
            if await self.perform(request, model: model), !Task.isCancelled { completion() }
        }
    }

    func startModeSwitch(model: ScanModel, completion: @escaping @MainActor () -> Void) {
        model.startTrackedApplicationTask {
            if await self.switchMode(model: model), !Task.isCancelled { completion() }
        }
    }

    private func invoke(root: URL, request: [String: Any], demo: Bool) async throws -> Data {
        if let operation { return try await operation(root, request, demo) }
        guard let execution = await Task.detached(priority: .utility, operation: {
            RuntimeWorkspace.prepareExecution(projectRoot: root)
        }).value,
        let invocation = execution.pinnedInvocation(relativePath: "scripts/skill_inventory.py", name: "skills"),
        let python = ScreeService.python3Path(signedBundleURL: execution.signedBundleURL) else {
            throw RetirementError(L10n.text("스킬 관리 실행 파일을 준비하지 못했습니다."))
        }
        var pinned = invocation.files
        var request = request
        request["demo"] = demo
        pinned["request"] = try JSONSerialization.data(withJSONObject: request)
        let wrapper = "import sys; source=open(sys.argv[1],'rb').read(); sys.argv=['skill_inventory.py']+sys.argv[2:]; exec(compile(source,'skill_inventory.py','exec'),{'__name__':'__main__'})"
        let result = await LocalProcessRunner.capture(executable: python,
            arguments: ["-I", "-B", "-c", wrapper, invocation.argument, "--request-file", "@pch-pinned:request"],
            currentDirectory: execution.runtimeRoot, expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
            expectedSignedBundleURL: execution.signedBundleURL, pinnedFiles: pinned, timeout: 180,
            maxOutputBytes: 8_000_000, waitForCleanupOnStop: true)
        let data = Data(result.output.utf8)
        try Task.checkCancellation()
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let error = object["error"] as? String {
            throw RetirementError(error)
        }
        guard result.succeeded, !result.outputTruncated else { throw RetirementError(L10n.text("스킬 관리 응답을 확인하지 못했습니다. 새로고침하여 백업 기록을 확인하세요.")) }
        return data
    }

    @discardableResult
    func switchMode(model: ScanModel) async -> Bool {
        guard !busy, !model.applicationTerminationStarted else { return false }
        busy = true; error = ""
        defer { busy = false }
        let nextDemo = !demo
        do {
            let data = try await invoke(root: model.projectRoot,
                request: ["action": nextDemo ? "demo-create" : "status"], demo: nextDemo)
            try Task.checkCancellation()
            let nextSnapshot = try JSONDecoder().decode(SkillSnapshot.self, from: data)
            snapshot = nextSnapshot
            demo = nextDemo
            diff = ""
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func perform(_ request: [String: Any], model: ScanModel, mutation: Bool = false) async -> Bool {
        guard !busy, !model.applicationTerminationStarted else { return false }
        // Derive mutation authority from the operation as well as the caller.
        let mutates = mutation || ["disable", "restore"].contains(request["action"] as? String ?? "")
        if mutates, !demo, model.cleanupReviewOnly {
            error = CleanupExecutionService.reviewOnlyMessage
            return false
        }
        if mutates, model.isBusy {
            error = L10n.text("다른 작업이 끝난 뒤 다시 시도하세요.")
            return false
        }
        busy = true; error = ""
        let usingDemo = demo
        if request["action"] as? String == "compare" { diff = "" }
        if mutates { model.cleanupInFlight = true; model.beginDestructiveCleanupTransaction() }
        defer {
            busy = false
            if mutates { model.cleanupInFlight = false; model.finishDestructiveCleanupTransaction() }
        }
        do {
            let data = try await invoke(root: model.projectRoot, request: request, demo: usingDemo)
            if !mutates { try Task.checkCancellation() }
            if request["action"] as? String == "compare" {
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                guard let comparison = object?["diff"] as? String else {
                    throw RetirementError(L10n.text("비교 응답을 확인하지 못했습니다."))
                }
                diff = comparison == "SKILL.md 내용이 같습니다."
                    ? L10n.text("SKILL.md 내용이 같습니다.") : comparison
            } else {
                snapshot = try JSONDecoder().decode(SkillSnapshot.self, from: data)
            }
            return true
        } catch {
            self.error = error.localizedDescription
            if mutates, let data = try? await invoke(root: model.projectRoot, request: ["action": "status"], demo: usingDemo),
               let refreshed = try? JSONDecoder().decode(SkillSnapshot.self, from: data) {
                snapshot = refreshed
            }
            return false
        }
    }
}
