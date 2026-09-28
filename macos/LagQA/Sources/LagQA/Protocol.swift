import Foundation

struct Phase: Codable, Equatable {
    let id: String
    let title: String
    let instruction: String
    let seconds: Int
    static let standard: [Phase] = [
        .init(id: "prepare", title: "준비", instruction: "ChatGPT로 돌아가세요. 사진 한 장을 준비하고, 음성 안내에 따라 조작하세요. 메시지는 보내지 마세요.", seconds: 8),
        .init(id: "idle", title: "아무 조작 없이 대기", instruction: "지금은 마우스와 키보드를 움직이지 말고 기다려 주세요.", seconds: 10),
        .init(id: "first-input", title: "처음 입력하기", instruction: "이제 입력창을 클릭하고 짧은 문장을 쓰세요. 첫 글자가 나타날 때 끊기는지 확인하세요.", seconds: 12),
        .init(id: "typing", title: "계속 입력하기", instruction: "같은 입력창에서 문장을 계속 써보세요. 전송하지 마세요.", seconds: 10),
        .init(id: "sidebar", title: "채팅 목록으로 이동", instruction: "포인터를 왼쪽 채팅 목록 위아래로 움직인 뒤 입력창으로 돌아오세요. 대화를 클릭하지는 마세요.", seconds: 15),
        .init(id: "attachment", title: "사진 첨부하기", instruction: "평소 방식으로 사진 한 장을 첨부하세요. 미리보기가 나타나는 동안 끊기는지 확인하세요. 전송하지 마세요.", seconds: 20),
        .init(id: "settle", title: "마무리 대기", instruction: "조작을 멈추고 잠시 기다려 주세요.", seconds: 5)
    ]
    static func position(at elapsed: Double, phases: [Phase]) -> (index: Int, remaining: Int)? {
        var boundary = 0
        for (index, phase) in phases.enumerated() {
            boundary += phase.seconds
            if elapsed < Double(boundary) { return (index, max(1, Int(ceil(Double(boundary) - elapsed)))) }
        }
        return nil
    }
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
