import Foundation

struct Phase: Codable, Equatable {
    let id: String
    let title: String
    let instruction: String
    let seconds: Int
    static let standard: [Phase] = [
        .init(id: "first-input", title: "처음 입력하기", instruction: "", seconds: 0),
        .init(id: "typing", title: "계속 입력하기", instruction: "", seconds: 0),
        .init(id: "sidebar", title: "채팅 목록으로 이동", instruction: "", seconds: 0),
        .init(id: "attachment", title: "사진 첨부하기", instruction: "", seconds: 0)
    ]
}

// A real recording belongs to the user. Only the explicit diagnostic harness
// may finish automatically; an idle user is not evidence of a completed action.
enum RecordingPolicy {
    static func shouldFinish(elapsed: Double, smoke: Bool) -> Bool { smoke && elapsed >= 12 }
}

struct CPUCounter {
    let birth: UInt64
    let totalNanoseconds: UInt64
    let timestamp: Double
    static func percent(previous: CPUCounter?, current: CPUCounter) -> Double? {
        guard let previous, previous.birth == current.birth,
              current.timestamp > previous.timestamp,
              current.totalNanoseconds >= previous.totalNanoseconds else { return nil }
        return Double(current.totalNanoseconds - previous.totalNanoseconds)
            / ((current.timestamp - previous.timestamp) * 1_000_000_000) * 100
    }
}
