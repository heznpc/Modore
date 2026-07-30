import Combine
import Foundation

@MainActor
final class ScanLogStore: ObservableObject {
    private static let retainedCharacterCount = 200_000
    private static let batchingThreshold = 20_000
    private static let publishDelayNanoseconds: UInt64 = 50_000_000

    @Published private(set) var text = ""
    private var lines: [String] = []
    private var firstRetainedIndex = 0
    private var retainedCharacterCount = 0
    private var publishTask: Task<Void, Never>?

    var isEmpty: Bool {
        firstRetainedIndex >= lines.count
    }

    func append(_ line: String) {
        let wasPublishedEmpty = text.isEmpty
        if line.count >= Self.retainedCharacterCount {
            lines = [String(line.suffix(Self.retainedCharacterCount))]
            firstRetainedIndex = 0
            retainedCharacterCount = lines[0].count
        } else {
            if !isEmpty { retainedCharacterCount += 1 }
            lines.append(line)
            retainedCharacterCount += line.count
            discardOldestLinesUntilBounded()
        }

        if wasPublishedEmpty
            || line.count >= Self.retainedCharacterCount
            || retainedCharacterCount < Self.batchingThreshold {
            publishNow()
        } else {
            schedulePublish()
        }
    }

    func clear() {
        publishTask?.cancel()
        publishTask = nil
        lines.removeAll(keepingCapacity: false)
        firstRetainedIndex = 0
        retainedCharacterCount = 0
        text = ""
    }

    private func discardOldestLinesUntilBounded() {
        while retainedCharacterCount > Self.retainedCharacterCount,
              firstRetainedIndex < lines.count {
            retainedCharacterCount -= lines[firstRetainedIndex].count
            firstRetainedIndex += 1
            if firstRetainedIndex < lines.count {
                retainedCharacterCount -= 1
            }
        }

        if firstRetainedIndex >= 512, firstRetainedIndex * 2 >= lines.count {
            lines.removeFirst(firstRetainedIndex)
            firstRetainedIndex = 0
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.publishDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.publishNow()
        }
    }

    private func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        if isEmpty {
            text = ""
        } else {
            text = lines[firstRetainedIndex...].joined(separator: "\n")
        }
    }
}
