import Foundation

extension ScanModel {
    /// One user action discovers paths and checks their current use. It never
    /// selects items, opens an approval, or executes a cleanup. A cancelled or
    /// superseded scan must not investigate an older snapshot.
    func prepareStorageReview(
        additionalCandidates: @escaping @Sendable () async -> [StorageItem] = {
            await Task.detached(priority: .utility) {
                (SupplementalStorageAudit.latest()?.candidates ?? [])
                    + (DiskBalance.latest()?.candidates ?? [])
            }.value
        }
    ) {
        guard !isBusy, !applicationTerminationStarted else { return }
        runScan()
        guard let scan = scanTask, isRunning else { return }
        let generation = scanGeneration
        startTrackedApplicationTask { [weak self] in
            await scan.value
            guard let self, !Task.isCancelled, !self.applicationTerminationStarted,
                  self.scanGeneration == generation, self.state == .finished,
                  let storage = self.storage else { return }
            let additional = await additionalCandidates()
            guard !Task.isCancelled, !self.applicationTerminationStarted,
                  self.scanGeneration == generation, !self.isBusy else { return }
            self.investigateStorage(StorageInvestigation.inventory(storage) + additional)
        }
    }

    /// Investigation never opens an approval sheet or executes a cleanup.
    func investigateStorage(_ items: [StorageItem]) {
        guard !isBusy, !applicationTerminationStarted else { return }
        var seen = Set<String>()
        let candidates = items.filter { item in
            item.hasSupportedCleanupRecipe && seen.insert(SpaceGoalSelection.key(item)).inserted
                && (!CleanupExecutionRequest.isRequired(for: item.cleanupID) || CleanupExecutionRequest(item: item) != nil)
        }
        guard !candidates.isEmpty else { return }
        cleanupInFlight = true
        storageInvestigationProgress = CleanupRecoveryProgress(completedCount: 0, totalCount: candidates.count,
            currentLabel: L10n.text("조사 준비 중"))
        errorMessage = nil
        // Retain unrelated evidence; only the explicitly retried rows become pending.
        for item in candidates { storageInvestigations.removeValue(forKey: SpaceGoalSelection.key(item)) }
        cleanupTask = Task {
            defer {
                cleanupInFlight = false
                storageInvestigationProgress = nil
                cleanupTask = nil
            }
            guard let context = await cleanupExecution.prepare(projectRoot), !Task.isCancelled else {
                if !Task.isCancelled { errorMessage = L10n.text("조사 도구의 서명을 검증하지 못했습니다. 앱을 다시 설치한 뒤 조사하세요.") }
                return
            }
            let results = await CleanupPreviewBatch.run(
                candidates.map { ($0.cleanupID, CleanupExecutionRequest(item: $0)) },
                context: context, client: cleanupExecution,
                budget: min(180, max(30, Double(candidates.count) * 6)),
                progress: { [weak self] completed, total in
                    self?.storageInvestigationProgress = CleanupRecoveryProgress(
                        completedCount: completed, totalCount: total, currentLabel: L10n.text("크기·사용 상태·재생성 근거 조사"))
                }, onResult: { [weak self] index, result in
                    guard !Task.isCancelled else { return }
                    let item = candidates[index]
                    self?.storageInvestigations[SpaceGoalSelection.key(item)] = .evidence(item: item, result: result, pathMissing: StorageInvestigation.pathIsMissing(item))
                }
            )
            guard !Task.isCancelled, !applicationTerminationStarted else { return }
            for (index, item) in candidates.enumerated() where results[index] == nil {
                storageInvestigations[SpaceGoalSelection.key(item)] = .evidence(item: item, result: nil)
            }
            await refreshLiveState()
        }
    }
}
