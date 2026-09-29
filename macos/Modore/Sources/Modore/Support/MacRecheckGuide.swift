import Darwin
import Foundation

enum MacRecheckGuide {
    enum Processor: String, CaseIterable, Identifiable {
        case appleSilicon = "Apple silicon"
        case intel = "Intel"

        var id: String { rawValue }

        static var current: Processor {
            var supportsArm64: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let result = sysctlbyname("hw.optional.arm64", &supportsArm64, &size, nil, 0)
            return result == 0 && supportsArm64 == 1 ? .appleSilicon : .intel
        }

        var instructions: [String] {
            switch self {
            case .appleSilicon:
                return [
                    L10n.text("Mac을 종료합니다."),
                    L10n.text("전원 버튼을 길게 눌러 시동 옵션 화면이 나오면 놓습니다."),
                    L10n.text("⌘D를 길게 눌러 Apple 진단을 시작합니다."),
                    L10n.text("화면의 안내에 따라 검사하고 결과 코드를 기록합니다."),
                ]
            case .intel:
                return [
                    L10n.text("Mac을 종료합니다."),
                    L10n.text("전원을 켠 직후 D 키를 길게 누릅니다."),
                    L10n.text("진행 표시줄 또는 언어 선택 화면이 나오면 놓습니다. 시작되지 않으면 Option-D로 다시 시도합니다."),
                    L10n.text("화면의 안내에 따라 검사하고 결과 코드를 기록합니다."),
                ]
            }
        }
    }

    static let timeMachineSettings = URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!
    static let backupHelp = URL(string: "https://support.apple.com/ko-kr/104984")!
    static let diagnosticsHelp = URL(string: "https://support.apple.com/ko-kr/102550")!
    static let resultHelp = URL(string: "https://support.apple.com/ko-kr/102334")!

    static let preparation = L10n.text("작업과 백업을 마친 뒤 외장 디스크를 안전하게 추출하세요. 전원 연결부가 마른 상태인지 확인하고, 검사에 필요한 전원·키보드·마우스·디스플레이·이더넷 외의 주변 기기를 분리하세요.")

    static func copiedInstructions(for processor: Processor) -> String {
        let steps = processor.instructions.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        return [
            L10n.format("Apple 진단 · %@", processor.rawValue),
            preparation,
            steps,
            L10n.text("재시동 후 Modore > Mac 재점검에서 결과를 기록하세요."),
            L10n.format("실행 안내: %@", diagnosticsHelp.absoluteString),
            L10n.format("결과 코드: %@", resultHelp.absoluteString),
        ].joined(separator: "\n\n")
    }
}
