import SwiftUI

struct ApplicationWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot

    var body: some View {
        List {
            Section {
                ForEach(storage.applications) { item in
                    WorkspaceStorageItemRow(
                        item: item,
                        fallbackSymbol: "app",
                        detail: item.path,
                        status: item.canCleanup ? nil : L10n.text("보호됨"),
                        actionTitle: item.canCleanup ? L10n.text("제거 검토…") : nil
                    ) {
                        model.prepareCleanup(item)
                    }
                    .contextMenu { StorageItemContextMenu(item: item) }
                }
            } header: {
                NativeSectionHeader(
                    title: L10n.text("설치 앱"),
                    subtitle: L10n.text("정확한 bundle ID로 확인된 앱만 제거 미리보기를 제공합니다."),
                    value: storage.applicationsText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(L10n.text("설치 앱"))
    }
}

struct SimulatorWorkspaceList: View {
    let storage: StorageSnapshot

    var body: some View {
        List {
            Section {
                ForEach(storage.simulatorBreakdown) { item in
                    SimulatorFootprintBreakdownRow(item: item)
                }

                if storage.simulatorFootprintMeasurementIncomplete {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.text("일부 관련 항목은 측정을 마치지 못했습니다"))
                                .font(.body.weight(.medium))
                            Text(L10n.text("표시된 합계는 확인된 최소량이며, 다시 검사하기 전에는 정확한 전체 크기로 보지 않습니다."))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "clock.badge.exclamationmark")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                NativeSectionHeader(
                    title: L10n.text("Simulator 관련 저장공간"),
                    subtitle: L10n.text("기기 데이터와 runtime 지원 자산, 공유 dyld/cache를 경로 중복 없이 합산합니다."),
                    value: simulatorFootprintText
                )
            }

            if !storage.simulatorCreationBursts.isEmpty {
                Section {
                    ForEach(storage.simulatorCreationBursts) { burst in
                        SimulatorCreationBurstRow(burst: burst)
                    }
                } header: {
                    NativeSectionHeader(
                        title: L10n.text("기기 생성 패턴"),
                        subtitle: L10n.text("생성 시각이 가까운 사실만 보여주며 Claude·Xcode 등 생성 주체를 단정하지 않습니다."),
                        value: L10n.format("%@개 묶음", String(describing: storage.simulatorCreationBursts.count))
                    )
                }
            }

            Section {
                if storage.simulatorDevices.isEmpty {
                    Label(L10n.text("등록된 Simulator 기기가 없습니다"), systemImage: "iphone")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(storage.simulatorDevices) { device in
                        WorkspaceSimulatorRow(device: device)
                    }
                }
            } header: {
                NativeSectionHeader(
                    title: L10n.text("Simulator 기기 데이터"),
                    subtitle: L10n.text("아래 작업은 개별 기기 데이터만 다루며 설치된 runtime 지원 자산은 유지합니다."),
                    value: deviceDataText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel(L10n.text("Simulator 관련 저장공간과 기기"))
    }

    private var simulatorFootprintText: String {
        guard storage.simulatorFootprintMeasurementIncomplete else {
            return storage.simulatorFootprintText
        }
        guard storage.simulatorFootprintGB > 0 else { return L10n.text("측정 보류") }
        return String(format: L10n.text("최소 %.1fGB"), storage.simulatorFootprintGB)
    }

    private var deviceDataText: String {
        if let breakdown = storage.simulatorBreakdown.first(where: {
            $0.kind.localizedCaseInsensitiveContains("device")
        }) {
            if breakdown.measureStatus != "ok" {
                return breakdown.sizeGB > 0
                    ? String(format: L10n.text("최소 %.1fGB"), breakdown.sizeGB)
                    : L10n.text("측정 보류")
            }
            return breakdown.sizeText
        }

        let measured = storage.simulatorDevices.filter { $0.measureStatus != "timed_out" }
        let total = measured.reduce(0.0) { $0 + $1.sizeGB }
        if measured.count != storage.simulatorDevices.count {
            return total > 0 ? String(format: L10n.text("최소 %.1fGB"), total) : L10n.text("측정 보류")
        }
        return total > 0 ? String(format: "%.1fGB", total) : "0GB"
    }
}

private struct SimulatorFootprintBreakdownRow: View {
    let item: SimulatorFootprintBreakdown

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.label)
                    .font(.body.weight(.medium))
                Text(L10n.message(detail))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(value)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.label), \(value). \(detail)")
    }

    private var value: String {
        guard item.measureStatus != "ok" else { return item.sizeText }
        return item.sizeGB > 0
            ? String(format: L10n.text("최소 %.1fGB"), item.sizeGB)
            : L10n.text("측정 보류")
    }

    private var detail: String {
        if item.measureStatus != "ok" {
            return item.sizeGB > 0
                ? L10n.text("확인된 최소량이며 일부 경로는 크기 측정을 마치지 못했습니다.")
                : L10n.text("이번 검사에서 크기 측정을 마치지 못했습니다.")
        }
        let kind = item.kind.lowercased()
        if kind.contains("device") { return L10n.text("각 Simulator 기기의 사용자 데이터") }
        if kind.contains("dyld") || kind.contains("cache") { return L10n.text("여러 기기가 함께 사용하는 실행 지원 캐시") }
        if kind.contains("runtime") || kind.contains("asset") { return L10n.text("설치된 OS runtime을 지원하는 공용 자산") }
        return L10n.text("Simulator 실행을 위해 보관된 관련 자산")
    }

    private var symbol: String {
        let kind = item.kind.lowercased()
        if kind.contains("device") { return "iphone" }
        if kind.contains("dyld") || kind.contains("cache") { return "memorychip" }
        if kind.contains("runtime") || kind.contains("asset") { return "shippingbox" }
        return "externaldrive"
    }
}

private struct SimulatorCreationBurstRow: View {
    let burst: SimulatorCreationBurst

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.format("같은 시각 %@개 일괄 생성", String(describing: burst.count)))
                    .font(.body.weight(.medium))
                Text("\(burst.runtime) · \(timeText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(L10n.text("생성 주체 미확인"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            L10n.format("같은 시각 %@개 일괄 생성, %@, %@, 생성 주체 미확인", String(describing: burst.count), String(describing: burst.runtime), String(describing: timeText))
        )
    }

    private var timeText: String {
        let timestamp = burst.createdAt.formatted(date: .abbreviated, time: .standard)
        let interval = max(0, burst.endedAt.timeIntervalSince(burst.createdAt))
        guard interval >= 1 else { return timestamp }
        return L10n.format("%@부터 %@초 이내", String(describing: timestamp), String(describing: Int(interval.rounded(.up))))
    }
}

private struct WorkspaceSimulatorRow: View {
    @EnvironmentObject private var model: ScanModel
    let device: SimulatorDevice

    @ViewBuilder
    var body: some View {
        if !isShutdown {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(
                    L10n.format("%@, %@, %@, 삭제 차단됨, %@", String(describing: device.name), String(describing: device.runtime), String(describing: stateDisplayText), String(describing: device.sizeText))
                )
        } else if model.hasUnresolvedSimulatorKeepEntries {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.format("%@, 기존 보존 목록 확인 필요, 삭제 차단됨, %@", String(describing: device.name), String(describing: device.sizeText)))
        } else if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: L10n.text("보존 해제")) {
                    model.toggleSimulatorProtection(device)
                }
        } else if !device.hasSupportedCleanupRecipe {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.format("%@, 정리 recipe 확인 필요, 삭제 차단됨, %@", String(describing: device.name), String(describing: device.sizeText)))
        } else if device.measureStatus == "timed_out" {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: L10n.text("다시 측정")) {
                    model.runScan()
                }
        } else {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: L10n.text("보존")) {
                    model.toggleSimulatorProtection(device)
                }
                .accessibilityAction(named: L10n.text("삭제 검토")) {
                    model.prepareCleanup(device)
                }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 12) {
            Image(systemName: device.isBooted ? "iphone.radiowaves.left.and.right" : "iphone")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text("\(device.runtime) · \(statusText)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(device.sizeText)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 72, alignment: .trailing)
            simulatorActions
                .frame(minWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var simulatorActions: some View {
        if !isShutdown {
            Text(L10n.format("%@ · 삭제 차단", String(describing: stateDisplayText)))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if model.hasUnresolvedSimulatorKeepEntries {
            Text(L10n.text("보존 목록 확인 필요"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) {
            Button(L10n.text("보존 해제")) { model.toggleSimulatorProtection(device) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isBusy)
        } else if !device.hasSupportedCleanupRecipe {
            Text(L10n.text("다시 검사 필요"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if device.measureStatus == "timed_out" {
            Button(L10n.text("다시 측정")) { model.runScan() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isBusy)
        } else {
            HStack(spacing: 8) {
                Button(L10n.text("보존")) { model.toggleSimulatorProtection(device) }
                    .buttonStyle(.bordered)
                Button(L10n.text("삭제 검토…")) { model.prepareCleanup(device) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            .disabled(model.isBusy)
        }
    }

    private var statusText: String {
        if !isShutdown { return L10n.format("%@ · 삭제 차단", String(describing: stateDisplayText)) }
        if model.hasUnresolvedSimulatorKeepEntries { return L10n.text("기존 보존 목록 미확인 · 삭제 차단") }
        if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) { return L10n.text("보존됨") }
        if !device.hasSupportedCleanupRecipe { return L10n.text("정리 recipe 미확인 · 삭제 차단") }
        if device.measureStatus == "timed_out" { return L10n.text("측정 보류") }
        return device.state
    }

    private var isShutdown: Bool {
        device.state == "Shutdown"
    }

    private var stateDisplayText: String {
        switch device.state {
        case "Booted": return L10n.text("실행 중")
        case "Creating": return L10n.text("생성 중")
        case "Shutting Down": return L10n.text("종료 중")
        case "Shutdown": return L10n.text("종료됨")
        case "", "Unknown": return L10n.text("상태 미확인")
        default: return device.state
        }
    }
}
