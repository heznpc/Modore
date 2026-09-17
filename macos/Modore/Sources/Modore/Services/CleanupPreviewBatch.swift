import Foundation

/// Read-only previews share a bounded budget. An unresponsive candidate must
/// not discard valid capabilities obtained for unrelated candidates.
enum CleanupPreviewBatch {
    static func run(
        _ requests: [(String, CleanupExecutionRequest?)],
        context: CleanupExecutionContext,
        client: CleanupExecutionClient,
        budget: TimeInterval = 30,
        progress: @escaping @MainActor @Sendable (Int, Int) -> Void
    ) async -> [Int: CapturedProcessResult] {
        guard !requests.isEmpty else { return [:] }
        return await withTaskGroup(of: (Int, CapturedProcessResult?).self) { group in
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, budget) * 1_000_000_000))
                return (-1, nil)
            }
            var next = 0
            var results: [Int: CapturedProcessResult] = [:]
            func enqueue(_ index: Int) {
                let request = requests[index]
                group.addTask {
                    (index, await client.preview(request.0, request.1, context))
                }
            }
            // Keep process and I/O pressure bounded on the machine being rescued.
            while next < min(2, requests.count) {
                enqueue(next)
                next += 1
            }
            while let (index, result) = await group.next() {
                if index == -1 || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                results[index] = result
                await progress(results.count, requests.count)
                if results.count == requests.count {
                    group.cancelAll()
                    break
                }
                if next < requests.count {
                    enqueue(next)
                    next += 1
                }
            }
            return results
        }
    }
}
