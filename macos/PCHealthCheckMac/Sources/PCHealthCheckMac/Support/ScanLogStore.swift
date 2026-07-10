import Combine
import Foundation

@MainActor
final class ScanLogStore: ObservableObject {
    private static let retainedCharacterCount = 200_000

    @Published private(set) var text = ""
    private var characterCount = 0

    var isEmpty: Bool { text.isEmpty }

    func append(_ line: String) {
        if text.isEmpty {
            text = line
            characterCount = line.count
        } else {
            text.append("\n")
            text.append(line)
            characterCount += 1 + line.count
        }

        if characterCount > Self.retainedCharacterCount {
            let retained = text.suffix(Self.retainedCharacterCount)
            let firstNewline = retained.firstIndex(of: "\n")
            text = firstNewline.map { String(retained[retained.index(after: $0)...]) }
                ?? String(retained)
            characterCount = text.count
        }
    }

    func clear() {
        text = ""
        characterCount = 0
    }
}
