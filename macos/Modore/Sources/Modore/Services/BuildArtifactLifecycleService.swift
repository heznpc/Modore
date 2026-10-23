import Foundation

struct BuildArtifactReport: Decodable {
    struct Item: Decodable, Identifiable {
        let id, runID, kind, path, reason, status, validation: String
        let bytes: Int64?
        let eligible: Bool
        let startedAt: Double
        let finishedAt: Double?
        let installedPaths: [String]
        let previousInstalledPaths: [String]
    }
    let observedAt: Double
    let items: [Item]
    let sharedCache, policy: String
    let warnings: [String]?
}

@MainActor
final class BuildArtifactLifecycleService: ObservableObject {
    @Published var report: BuildArtifactReport?
    @Published var busy = false
    @Published var error: String?

    func refresh(model: ScanModel, reclaim: Bool = false, identifiers: [String] = []) async {
        guard !busy, !model.isBusy else { return }
        if reclaim && model.cleanupReviewOnly {
            error = CleanupExecutionService.reviewOnlyMessage
            return
        }
        var lease: AppInstanceCoordinator.Lease?
        if reclaim {
            guard !identifiers.isEmpty else { return }
            let lock = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Modore/cleanup-execution-lock")
            guard case .acquired(let acquired) = AppInstanceCoordinator.acquireLease(at: lock) else {
                error = "다른 정리 작업이 실행 중입니다. 종료 후 다시 확인해 주세요."
                return
            }
            lease = acquired
            model.cleanupInFlight = true
            model.beginDestructiveCleanupTransaction()
        }
        busy = true; error = nil
        defer {
            busy = false
            if reclaim {
                model.cleanupInFlight = false
                model.finishDestructiveCleanupTransaction()
            }
            withExtendedLifetime(lease) {}
        }
        do {
            let arguments = [reclaim ? "reclaim" : "report"] + identifiers.flatMap { ["--artifact-id", $0] }
            let data = try await Self.invoke(root: model.projectRoot, arguments: arguments)
            report = try JSONDecoder().decode(BuildArtifactReport.self, from: data)
        } catch { self.error = error.localizedDescription }
    }

    func connectInstalled(_ item: BuildArtifactReport.Item, model: ScanModel) async {
        guard !busy else { return }
        busy = true; error = nil
        do {
            let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Modore.app")
            let path = FileManager.default.fileExists(atPath: local.path) ? local.path : "/Applications/Modore.app"
            _ = try await Self.invoke(root: model.projectRoot, arguments: ["link", "--id", item.runID, "--path", path])
        } catch { self.error = error.localizedDescription }
        busy = false
        if error == nil { await refresh(model: model) }
    }

    private static func invoke(root: URL, arguments: [String]) async throws -> Data {
        try await NativeOperationService.capture("build-artifacts", payload: JSONSerialization.data(withJSONObject: ["arguments": arguments]),
            timeout: 300, maximumBytes: 4_000_000)
    }
}
