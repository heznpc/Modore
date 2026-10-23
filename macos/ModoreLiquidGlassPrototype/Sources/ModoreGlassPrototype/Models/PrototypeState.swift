import SwiftUI
import Observation

enum WorkspaceArea: String, CaseIterable, Identifiable {
    case health, storage, work
    var id: Self { self }
    var title: String {
        switch self { case .health: "Mac 상태"; case .storage: "저장공간"; case .work: "개발 작업" }
    }
    var symbol: String {
        switch self { case .health: "macbook"; case .storage: "internaldrive"; case .work: "folder.badge.gearshape" }
    }
}

enum HealthScenario: String, CaseIterable, Identifiable {
    case attention = "주의 필요", normal = "정상", unavailable = "미측정"
    var id: Self { self }
}

enum PrototypeAppearance: String, CaseIterable, Identifiable {
    case system = "시스템", light = "밝게", dark = "어둡게"
    var id: Self { self }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

@MainActor @Observable final class PrototypeState {
    var area: WorkspaceArea? = .health
    var scenario: HealthScenario = .attention
    var appearance: PrototypeAppearance = .system
    var observedAt = Date()
    var refreshing = false
    var storageSelection: String? = "derived"
    var cleanupSelection: Set<String> = []
    var showStorageInspector = true
    var projectID = "modore"
    var conversationID: String? = "design"
    var workQuery = ""

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        try? await Task.sleep(for: .milliseconds(650))
        observedAt = Date()
        refreshing = false
    }
}

struct StorageItem: Identifiable, Hashable {
    let id: String
    let name: String
    let detail: String
    let gib: Double
    let symbol: String
    let path: String
    let eligible: Bool
    let status: String
    let explanation: String
    var size: String { String(format: "%.1f GiB", gib) }

    static let samples: [Self] = [
        .init(id: "derived", name: "Xcode 빌드 캐시", detail: "DerivedData · 12개 프로젝트", gib: 8.4, symbol: "hammer", path: "~/Library/Developer/Xcode/DerivedData", eligible: true, status: "재생성 가능", explanation: "빌드 과정에서 다시 만들어지는 중간 산출물입니다. 정리 후 첫 빌드는 시간이 더 걸릴 수 있습니다. 소스 코드와 아카이브는 포함하지 않습니다."),
        .init(id: "packages", name: "패키지 다운로드 캐시", detail: "Swift Package Manager", gib: 2.1, symbol: "shippingbox", path: "~/Library/Caches/org.swift.swiftpm", eligible: true, status: "재생성 가능", explanation: "다시 다운로드할 수 있는 패키지 캐시입니다. 다음 빌드에서 네트워크 연결이 필요할 수 있습니다. 프로젝트의 Package.resolved는 보존합니다."),
        .init(id: "simulators", name: "시뮬레이터 데이터", detail: "iOS 개발 기기 · 4개", gib: 24.6, symbol: "iphone", path: "~/Library/Developer/CoreSimulator/Devices", eligible: false, status: "사용 중", explanation: "실행 중인 시뮬레이터가 포함되어 있어 정리 대상에서 제외했습니다. 기기별 앱 데이터와 상태를 확인한 후 별도로 검토해야 합니다."),
        .init(id: "archives", name: "앱 아카이브", detail: "배포 기록 · 9개", gib: 15.8, symbol: "archivebox", path: "~/Library/Developer/Xcode/Archives", eligible: false, status: "보존 권장", explanation: "배포한 앱과 디버그 심볼이 포함될 수 있습니다. 크기만으로 삭제를 권하지 않으며 기본 정리 대상에서 제외합니다."),
        .init(id: "projects", name: "프로젝트", detail: "작업 폴더 · 18개", gib: 41.2, symbol: "folder", path: "~/Developer", eligible: false, status: "원본 보존", explanation: "소스 코드와 로컬 변경 사항이 있는 작업 폴더입니다. 개발 작업 화면에서 프로젝트와 대화를 함께 확인할 수 있습니다."),
        .init(id: "sessions", name: "AI 대화 기록", detail: "프로젝트에 연결된 원본", gib: 3.7, symbol: "text.bubble", path: "~/.local/share/ai-sessions", eligible: false, status: "원본 보존", explanation: "프로젝트의 의사결정과 작업 맥락을 담은 기록입니다. 원본을 보존하고 필요한 대화만 찾아 읽는 흐름을 제공합니다.")
    ]
}

struct ProjectSample: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let conversations: [ConversationSample]
    static let samples: [Self] = [
        .init(id: "modore", name: "Modore", subtitle: "Mac 유틸리티", conversations: [
            .init(id: "design", title: "Mac 앱의 새 디자인 방향", source: "Codex", time: "오늘 14:32", summary: "상태를 읽고, 대상을 고르고, 같은 맥락에서 검토하기.", paragraphs: ["현재 상태에서 무엇을 확인해야 하는지 먼저 보여주세요. 숫자마다 큰 카드를 만들기보다, 관련된 정보를 한 행에서 비교할 수 있으면 좋겠습니다.", "사이드바는 Mac 상태, 저장공간, 개발 작업의 세 영역으로 정리했습니다. 시스템 툴바와 사이드바가 탐색을 담당하고 본문은 선택한 대상에 집중합니다.", "저장공간에서는 항목을 열어보는 선택과 정리 대상으로 체크하는 동작을 분리합니다. 검토 시트에서 경로와 보존 대상을 확인한 뒤 다음 단계로 이어집니다."]),
            .init(id: "storage-flow", title: "저장공간 검토 흐름", source: "Claude", time: "어제 18:10", summary: "크기보다 먼저 확인할 것은 사용 여부와 재생성 가능성.", paragraphs: ["빌드 캐시와 프로젝트 원본은 같은 삭제 목록에 넣지 않습니다. 정리 후보의 근거를 먼저 읽을 수 있어야 합니다.", "사용 중인 시뮬레이터는 제외 이유를 해당 행에서 보여줍니다. 아카이브와 원본 대화는 보존 대상으로 표시합니다.", "예상 파일 크기와 실제 확보한 디스크 공간은 다를 수 있습니다. 실행 결과에서는 두 수치를 분리해서 보여줍니다."]),
            .init(id: "build", title: "실행본 확인과 빌드 경로", source: "Codex", time: "10월 17일", summary: "새로 만든 앱을 정확한 번들 경로로 실행하기.", paragraphs: ["프로토타입은 제품 앱과 다른 번들 ID를 사용합니다. 앱 이름으로 검색해서 예전 설치본이 실행되는 상황을 피합니다.", "실행 스크립트는 빌드에 성공한 바이너리만 앱 번들에 담고, 그 경로를 직접 엽니다. 화면에서도 빌드 시간을 확인할 수 있습니다."])
        ]),
        .init(id: "sample-app", name: "Sample App", subtitle: "SwiftUI 실험", conversations: [
            .init(id: "sample-a11y", title: "키보드로 탐색하기", source: "Codex", time: "10월 16일", summary: "목록 선택과 메뉴 명령을 같은 동작으로 연결하기.", paragraphs: ["사이드바는 기본 List 선택을 사용합니다. 메뉴의 이동 명령으로도 세 화면에 접근할 수 있습니다.", "색상에만 의존하지 않고 상태 이름과 아이콘을 함께 표시합니다."])
        ])
    ]
}

struct ConversationSample: Identifiable {
    let id: String
    let title: String
    let source: String
    let time: String
    let summary: String
    let paragraphs: [String]
}
