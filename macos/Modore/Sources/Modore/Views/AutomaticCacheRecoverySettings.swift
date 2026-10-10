import SwiftUI

struct AutomaticCacheRecoverySettings: View {
    @EnvironmentObject private var recovery: AutomaticCacheRecovery
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var monitor: CPUWatchService
    var body: some View {
        Section(L10n.text("자동 공간 확보")) {
            Toggle(L10n.text("공간 부족 시 재생성 가능한 미사용 데이터 자동 정리"), isOn: Binding(
                get: { recovery.enabled }, set: { recovery.setEnabled($0) }
            ))
            if recovery.requiresConsentReview {
                Text(L10n.text("이전 동의의 정리 범위를 확인할 수 없거나 범위가 변경됐습니다. 아래 범위를 확인한 뒤 자동 정리를 다시 켜세요."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(L10n.text("여유 공간이 20GiB 미만이면 업데이트 다운로드·Chrome 임시 복제본·테스트 브라우저·패키지 캐시·Xcode 빌드 데이터를 측정해 큰 항목부터 정리합니다. 문서·개발 프로젝트·기존 워크트리 안의 미사용 Swift 컴파일 산출물도 확인합니다. 저장공간 감시를 켜 두면 앱을 닫아도 자동으로 실행됩니다. 소스·대화·node_modules·_npx·의존성 체크아웃·워크트리·시뮬레이터는 보존합니다."))
                .font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("사용 중인 항목은 건너뛰고, 실제 여유 공간 변화와 처리 기록을 남깁니다. 30분 간격으로 재평가하며, 처리한 캐시는 24시간 동안 다시 지우지 않습니다."))
                .font(.caption).foregroundStyle(.secondary)
            Text(recovery.detail).font(.caption).textSelection(.enabled)
            Button(L10n.text("지금 분석·자동 정리")) {
                Task { await recovery.runIfNeeded(model: model, snapshot: monitor.snapshot, requestedNow: true) }
            }.disabled(!recovery.enabled || recovery.running || model.cleanupInFlight)
            if let report = recovery.last { AutomaticRecoveryDetails(report: report) }
            Button(L10n.text("추가 확보 계획 열기")) {
                NSWorkspace.shared.open(URL(string: "modore://storage/recovery")!)
            }
            Button(L10n.text("분석·처리 기록 보기")) { recovery.revealReport() }
        }
    }
}
