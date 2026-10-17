import Foundation

extension ScanModel {
    /// A disk traversal owns the shared read slot until cancellation has drained
    /// its subprocess. Switching pages must not overlap the old traversal with
    /// a scan, CPU observation, or cleanup started on the destination page.
    @discardableResult
    func startStorageMeasurement(operation: @escaping @MainActor () async -> Void) -> Bool {
        guard !isBusy, !applicationTerminationStarted else { return false }
        storageMeasurementInFlight = true
        let identifier = startTrackedApplicationTask(scope: .storageScreen) { [weak self] in
            defer { self?.storageMeasurementInFlight = false }
            guard let self, !Task.isCancelled, !self.applicationTerminationStarted else { return }
            await operation()
        }
        if identifier == nil { storageMeasurementInFlight = false }
        return identifier != nil
    }

    func cancelStorageScreenTasks() {
        let tasks = cancelTrackedApplicationTasks(in: .storageScreen)
        retainPendingDrainTasks(tasks)
        // Keep storageMeasurementInFlight true until the owning task's defer.
    }
}
