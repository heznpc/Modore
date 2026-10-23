import SwiftUI

struct HealthDashboardTiles: View {
    let snapshot: HealthSnapshot
    // Historical peaks belong in the history/process detail, never in a current-status card.
    var peak: HealthSnapshot? = nil
    let storage: () -> Void
    let memory: () -> Void
    let cpu: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(spacing: 0) {
                tile(L10n.text("저장공간"), "internaldrive", value: HealthSnapshot.bytes(snapshot.freeBytes),
                     detail: L10n.text("실제 여유 공간"), status: storageStatus,
                     warning: snapshot.storagePressure?.needsRecovery == true,
                     unknown: snapshot.freeBytes == nil, action: L10n.text("사용 현황 보기"), run: storage)
                Divider().padding(.leading, 52)
                tile(L10n.text("메모리"), "memorychip", value: memoryStatus,
                     detail: L10n.text("macOS 메모리 압력"),
                     status: L10n.format("스왑 %@", HealthSnapshot.bytes(snapshot.swapBytes.map { Int64(clamping: $0) })),
                     warning: (snapshot.memoryPressure ?? 0) >= 2, unknown: snapshot.memoryPressure == nil,
                     action: L10n.text("메모리 사용 앱 확인"), run: memory)
                Divider().padding(.leading, 52)
                tile("CPU", "cpu", value: cpuStatus,
                     detail: L10n.text("관측한 프로세스 기준"), status: thermalStatus,
                     warning: snapshot.cpuElevated || snapshot.cpuBurst == true,
                     unknown: !snapshot.cpuAvailable, action: L10n.text("실행 작업 보기"), run: cpu)
                Divider().padding(.leading, 52)
                if let power = snapshot.power {
                    passiveRow(L10n.text("전원"), icon: power.source == .battery ? "battery.100" : "powerplug", value: powerText(power), detail: power.lowPowerMode ? L10n.text("저전력 모드") : L10n.text("최근 관찰"))
                } else {
                    passiveRow(L10n.text("전원"), icon: "powerplug", value: L10n.text("미확인"), detail: L10n.text("측정 기준과 범위"))
                }
                Divider().padding(.leading, 52)
                if let connectivity = snapshot.connectivity {
                    passiveRow(L10n.text("네트워크"), icon: "network", value: connectivityText(connectivity), detail: L10n.text("네트워크 경로 상태는 인터넷 접속 성공이나 속도 측정 결과가 아닙니다."))
                } else {
                    passiveRow(L10n.text("네트워크"), icon: "network", value: L10n.text("미확인"), detail: L10n.text("측정 기준과 범위"))
                }
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15), lineWidth: 0.5))
            DisclosureGroup(L10n.text("측정 기준과 범위")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("실제 여유 공간 20 GiB 미만은 주의, 5 GiB 미만은 위험입니다. 정리 후 확보량도 실제 여유 공간의 변화로 확인합니다."))
                    if let capacity = snapshot.storageCapacity {
                        Text(L10n.format("macOS 중요 작업용 가용량 %@ · 임시 작업용 %@",
                            HealthSnapshot.bytes(capacity.importantAvailableBytes),
                            HealthSnapshot.bytes(capacity.opportunisticAvailableBytes)))
                        Text(L10n.text("가용량에는 macOS가 회수할 수 있는 공간이 포함될 수 있습니다. 실제 여유 공간이나 정리할 파일 크기와 더하지 않습니다."))
                    }
                    Text(L10n.format("압축 메모리 %@ · 스왑만으로 메모리 부족을 판정하지 않습니다.",
                        HealthSnapshot.bytes(snapshot.compressedBytes.map { Int64(clamping: $0) })))
                    if let coverage = snapshot.cpuCoverage {
                        Text(L10n.format("CPU 구간 측정 %@개 · 측정 제외 %@개",
                            String(coverage.measuredProcesses), String(coverage.unavailableProcesses)))
                    }
                    Text(L10n.text("CPU 100%는 코어 1개입니다. 보호된 프로세스는 측정에서 빠질 수 있으며 열 압력은 온도 센서값이 아닙니다."))
                    Text(L10n.text("네트워크 경로 상태는 인터넷 접속 성공이나 속도 측정 결과가 아닙니다."))
                }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
            }.font(.callout)
        }
    }

    private var storageStatus: String {
        switch snapshot.storagePressure {
        case .normal: return L10n.text("여유 있음")
        case .warning: return L10n.text("주의")
        case .danger: return L10n.text("위험")
        case nil: return L10n.text("미확인")
        }
    }
    private var memoryStatus: String {
        switch snapshot.memoryPressure {
        case 1: return L10n.text("정상")
        case 2: return L10n.text("주의")
        case 4: return L10n.text("위험")
        default: return L10n.text("미확인")
        }
    }
    private var cpuStatus: String {
        guard snapshot.cpuAvailable else { return L10n.text("측정 중") }
        if snapshot.cpuElevated { return L10n.text("부하 지속") }
        if snapshot.cpuBurst == true { return L10n.text("순간 부하") }
        return L10n.text("관측 부하 낮음")
    }
    private var thermalStatus: String {
        if snapshot.thermalPressure < 0 { return L10n.text("열 압력 미확인") }
        return snapshot.thermalPressure > 0 ? L10n.text("열 압력 감지") : L10n.text("열 압력 정상")
    }
    private func powerText(_ power: PowerSnapshot) -> String {
        let source: String
        switch power.source {
        case .external: source = L10n.text("외부 전원")
        case .battery: source = L10n.text("배터리")
        case .ups: source = "UPS"
        case .unknown: source = L10n.text("전원 미확인")
        }
        if let percent = power.batteryPercent {
            return source + " · \(percent)%" + (power.isCharging == true ? " · " + L10n.text("충전 중") : "")
        }
        return source
    }
    private func connectivityText(_ path: ConnectivitySnapshot) -> String {
        switch path.status {
        case .available: return L10n.text("네트워크 경로 연결됨")
        case .unavailable: return L10n.text("네트워크 경로 없음")
        case .connectionRequired: return L10n.text("네트워크 연결 필요")
        }
    }
    private func tile(_ name: String, _ icon: String, value: String, detail: String, status: String,
                      warning: Bool, unknown: Bool, action: String, run: @escaping () -> Void) -> some View {
        let color: Color = unknown ? .secondary : (warning ? .orange : .primary)
        return Button(action: run) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(name).fontWeight(.medium)
                    Text(detail + " · " + status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
                Text(value).font(.body.weight(.medium)).foregroundStyle(color).monospacedDigit()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).accessibilityHidden(true)
            }.padding(17).contentShape(Rectangle())
        }.buttonStyle(.plain).help(action)
    }

    private func passiveRow(_ name: String, icon: String, value: String, detail: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(.secondary).frame(width: 24).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(name).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }.padding(17)
    }
}

struct HealthActionTile: View {
    let title, subtitle, icon: String
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            HStack(spacing:14) {
                Image(systemName:icon).font(.title3).foregroundStyle(.secondary).frame(width:24)
                VStack(alignment:.leading,spacing:6) { Text(title).font(.headline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Image(systemName:"chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                .background(Color.secondary.opacity(0.045),in:RoundedRectangle(cornerRadius:16)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
