import Foundation
@preconcurrency import UserNotifications

@MainActor
final class CIWatchService: ObservableObject {
    @Published private(set) var snapshot: CISnapshot?
    @Published private(set) var busy = false
    @Published var message = ""
    @Published var showIncidents = false
    @Published private(set) var enabled = UserDefaults.standard.bool(forKey: "ciWatchEnabled")
    private var task: Task<Void, Never>?

    func start(model: ScanModel) {
        guard task == nil else { return }
        task = Task { [weak self, weak model] in
            guard let self, let model else { return }
            await self.load(root: model.projectRoot)
            repeat {
                if self.enabled { await self.refresh(model: model) }
                do { try await Task.sleep(nanoseconds: 300_000_000_000) } catch { break }
            } while !Task.isCancelled
        }
    }

    func setEnabled(_ value: Bool, model: ScanModel) async {
        enabled = value
        UserDefaults.standard.set(value, forKey: "ciWatchEnabled")
        if value {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !allowed { message = L10n.text("알림 권한이 꺼져 있습니다. CI 상태는 계속 갱신합니다.") }
            } catch { message = error.localizedDescription }
            await refresh(model: model)
        }
    }

    func invoke(root: URL, request: [String: Any]) async throws -> CISnapshot {
        let data = try await NativeOperationService.capture("ci", payload: JSONSerialization.data(withJSONObject: request),
            timeout: 240, maximumBytes: 4_000_000)
        return try JSONDecoder().decode(CISnapshot.self, from: data)
    }

    func load(root: URL) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { snapshot = try await invoke(root: root, request: ["action": "status"]) }
        catch { message = error.localizedDescription }
    }

    func refresh(model: ScanModel, repository: String = "") async {
        guard !busy, !model.applicationTerminationStarted else { return }
        busy = true; defer { busy = false }
        let paths = model.workProjects.filter { !$0.isUnassigned }.map(\.path)
        var request: [String: Any] = ["action": "refresh", "projects": paths,
                                     "discover": true, "notify": enabled]
        if !repository.trimmingCharacters(in: .whitespaces).isEmpty {
            request["repos"] = [repository.trimmingCharacters(in: .whitespaces)]
        }
        do {
            let fresh = try await invoke(root: model.projectRoot, request: request)
            snapshot = fresh
            message = ""
            if enabled { await deliver(fresh, root: model.projectRoot) }
        } catch { message = error.localizedDescription }
    }

    private func deliver(_ snapshot: CISnapshot, root: URL) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else {
            message = L10n.text("알림 권한이 꺼져 있습니다. CI 상태는 계속 갱신합니다.")
            return
        }
        guard !snapshot.events.isEmpty, enabled else { return }
        // One summary per observed change batch. Repeated failing runs do not add events.
        let freshCount = snapshot.events.filter { $0.kind == "failure" }.count
        let recoveredCount = snapshot.events.filter { $0.kind == "recovered" }.count
        let content = UNMutableNotificationContent()
        content.title = L10n.text("CI 상태 변경")
        content.body = L10n.format("새 실패 %d건 · 복구 %d건", freshCount, recoveredCount)
        content.userInfo = ["modoreRoute": "ci"]
        do {
            try await center.add(UNNotificationRequest(identifier: "modore-ci-" + snapshot.events.map(\.id).sorted().joined(separator: "-").prefix(180), content: content, trigger: nil))
            self.snapshot = try await invoke(root: root, request: ["action": "ack", "ids": snapshot.events.map(\.id)])
        } catch { message = error.localizedDescription }
    }
}
