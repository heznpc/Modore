import SwiftUI

struct AutomaticCacheRecoverySettings: View {
    @EnvironmentObject private var recovery: AutomaticCacheRecovery
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var monitor: CPUWatchService
    var body: some View {
        Section("자동 공간 확보") {
            Toggle("공간 부족 시 사용하지 않는 다운로드 캐시 자동 정리", isOn: $recovery.enabled)
            Text("여유 공간이 20GiB 미만이면 npm 다운로드·pip·Homebrew 캐시를 확인하고 정리합니다. 저장공간 감시를 켜 두면 앱을 닫아도 자동으로 실행됩니다. 다음 설치 때 다시 다운로드할 수 있습니다. 소스·대화·node_modules·_npx·시뮬레이터는 보존합니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text("사용 중인 항목은 건너뛰고, 실제 여유 공간 변화와 처리 기록을 남깁니다. 30분 간격으로 재평가하며, 처리한 캐시는 24시간 동안 다시 지우지 않습니다.")
                .font(.caption).foregroundStyle(.secondary)
            Text(recovery.detail).font(.caption).textSelection(.enabled)
            Button("지금 분석·자동 정리") {
                Task { await recovery.runIfNeeded(model: model, snapshot: monitor.snapshot, requestedNow: true) }
            }.disabled(!recovery.enabled || recovery.running || model.cleanupInFlight)
            Button("분석·처리 기록 보기") { recovery.revealReport() }
        }
    }
}
