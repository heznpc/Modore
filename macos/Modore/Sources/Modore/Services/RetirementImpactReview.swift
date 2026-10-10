import Combine
import Foundation

struct SessionImpactTarget: Equatable {
    let workspace: URL
    let repoURL: String?

    /// Previewed repositories can be investigated even when no Work index
    /// entry exists. GitHub identity, when known, complements the local path.
    static func selected(from items: [AssetRetirementItem], ids: Set<String>) -> [Self] {
        var seen: Set<String> = []
        return items.compactMap { item in
            guard ids.contains(item.id), !item.isFinished else { return nil }
            let workspace = URL(fileURLWithPath: item.path).standardizedFileURL
            guard seen.insert(workspace.path).inserted else { return nil }
            return Self(workspace: workspace, repoURL: item.remote.map { "https://github.com/\($0.full_name).git" })
        }
    }
}

/// Read-only investigation owned by the retirement sheet. The application
/// tracks the subprocess so leaving Work or quitting propagates cancellation.
/// Its results never participate in retirement approval or execution policy.
@MainActor
final class RetirementImpactReview: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var outcomes: [String: ScreeBindOutcome] = [:]
    @Published private(set) var observedAt: Date?
    private weak var owner: ScanModel?
    private var taskID: UUID?
    private var generation = 0
    private var activePaths: [String] = []

    func start(
        targets: [SessionImpactTarget], owner: ScanModel,
        using operation: (([SessionImpactTarget]) async -> [String: ScreeBindOutcome])? = nil
    ) {
        cancel()
        guard !targets.isEmpty else { return }
        self.owner = owner
        let root = owner.projectRoot
        generation += 1
        let request = generation
        activePaths = targets.map { $0.workspace.path }
        outcomes = [:]
        observedAt = nil
        isLoading = true
        taskID = owner.startTrackedApplicationTask(scope: .workScreen) { [weak self] in
            guard let self else { return }
            defer {
                if generation == request {
                    isLoading = false
                    taskID = nil
                    activePaths = []
                }
            }
            guard !Task.isCancelled else { return }
            let result: [String: ScreeBindOutcome]
            if let operation {
                result = await operation(targets)
            } else if let execution = await RuntimeWorkspace.prepareExecutionAsync(projectRoot: root), !Task.isCancelled {
                result = await ScreeService.bindAll(
                    execution: execution,
                    targets: targets.map { ($0.workspace, $0.repoURL) },
                    deep: true
                )
            } else {
                result = Dictionary(uniqueKeysWithValues: targets.map {
                    ($0.workspace.path, .failed(L10n.text("서명된 실행 런타임을 확인하지 못했습니다.")))
                })
            }
            guard !Task.isCancelled, generation == request else { return }
            outcomes = Dictionary(uniqueKeysWithValues: targets.map { target in
                (target.workspace.path, result[target.workspace.path] ?? .failed(L10n.text("이 저장소에 대한 바인딩 결과가 없습니다.")))
            })
            observedAt = Date()
        }
        if taskID == nil { isLoading = false }
    }

    func cancel() {
        generation += 1
        if let taskID { owner?.trackedApplicationTasks[taskID]?.task.cancel() }
        for path in activePaths {
            outcomes[path] = .failed(L10n.text("조사를 취소했습니다. 대화 연결 여부는 미확인입니다."))
        }
        activePaths = []
        taskID = nil
        isLoading = false
    }

    func reset() {
        cancel()
        outcomes = [:]
        observedAt = nil
    }
}
