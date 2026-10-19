import Foundation
@MainActor
final class WorkResourceService: ObservableObject {
    @Published var snapshot: WorkResourceSnapshot?
    @Published var busy = false
    @Published var message = ""
    func diagnose(root: URL) async {
        guard !busy else { return }
        busy = true
        do {
            _ = try await invoke(root: root, request: ["action": "diagnose-hooks", "project": root.path])
            message = L10n.text("Codex의 활성화·신뢰 상태를 확인했습니다.")
        } catch { message = error.localizedDescription }
        busy = false
        await refresh(root: root)
    }
    func invoke(root: URL, request: [String: Any]) async throws -> Data {
        try await NativeOperationService.capture("resources", payload: JSONSerialization.data(withJSONObject: request),
            timeout: 90, maximumBytes: 8_000_000)
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
