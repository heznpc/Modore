enum AppTerminationSafetyState: Equatable, Sendable {
    case safe
    case destructiveCleanupInProgress
}

@MainActor
final class AppTerminationSafetyGate {
    private var activeDestructiveTransactions = 0
    private var pendingTerminationReplies: [() -> Void] = []

    var state: AppTerminationSafetyState {
        activeDestructiveTransactions == 0 ? .safe : .destructiveCleanupInProgress
    }

    func beginDestructiveTransaction() {
        activeDestructiveTransactions += 1
    }

    func finishDestructiveTransaction() {
        guard activeDestructiveTransactions > 0 else { return }
        activeDestructiveTransactions -= 1
        guard activeDestructiveTransactions == 0 else { return }
        let replies = pendingTerminationReplies
        pendingTerminationReplies.removeAll(keepingCapacity: false)
        replies.forEach { $0() }
    }

    /// Returns true when termination must be delayed. The completion is never
    /// associated with a timeout or cancellation; it runs only after every
    /// destructive transaction reports completion.
    @discardableResult
    func deferTerminationUntilSafe(_ completion: @escaping () -> Void) -> Bool {
        guard activeDestructiveTransactions > 0 else { return false }
        pendingTerminationReplies.append(completion)
        return true
    }
}
