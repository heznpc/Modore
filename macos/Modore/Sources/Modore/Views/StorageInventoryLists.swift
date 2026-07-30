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
                        status: item.canCleanup ? nil : "보호됨",
                        actionTitle: item.canCleanup ? "제거 검토…" : nil
                    ) {
                        model.prepareCleanup(item)
                    }
                    .contextMenu { StorageItemContextMenu(item: item) }
                }
            } header: {
                NativeSectionHeader(
                    title: "설치 앱",
                    subtitle: "정확한 bundle ID로 확인된 앱만 제거 미리보기를 제공합니다.",
                    value: storage.applicationsText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("설치 앱")
    }
}

struct SimulatorWorkspaceList: View {
    let storage: StorageSnapshot

    var body: some View {
        List {
            Section {
                ForEach(storage.simulatorDevices) { device in
                    WorkspaceSimulatorRow(device: device)
                }
            } header: {
                NativeSectionHeader(
                    title: "Simulator 기기",
                    subtitle: "기기 데이터만 다루며 설치된 iOS runtime은 유지합니다.",
                    value: storage.simulatorText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("Simulator 기기")
    }
}

private struct WorkspaceSimulatorRow: View {
    @EnvironmentObject private var model: ScanModel
    let device: SimulatorDevice

    @ViewBuilder
    var body: some View {
        if device.isBooted {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(device.name), \(device.runtime), 실행 중, \(device.sizeText)")
        } else if model.hasUnresolvedSimulatorKeepEntries {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(device.name), 기존 보존 목록 확인 필요, 삭제 차단됨, \(device.sizeText)")
        } else if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "보존 해제") {
                    model.toggleSimulatorProtection(device)
                }
        } else if !device.hasSupportedCleanupRecipe {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(device.name), 정리 recipe 확인 필요, 삭제 차단됨, \(device.sizeText)")
        } else if device.measureStatus == "timed_out" {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "다시 측정") {
                    model.runScan()
                }
        } else {
            rowContent
                .accessibilityElement(children: .combine)
                .accessibilityAction(named: "보존") {
                    model.toggleSimulatorProtection(device)
                }
                .accessibilityAction(named: "삭제 검토") {
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
        if device.isBooted {
            Text("실행 중")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if model.hasUnresolvedSimulatorKeepEntries {
            Text("보존 목록 확인 필요")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) {
            Button("보존 해제") { model.toggleSimulatorProtection(device) }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isBusy)
        } else if !device.hasSupportedCleanupRecipe {
            Text("다시 검사 필요")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        } else if device.measureStatus == "timed_out" {
            Button("다시 측정") { model.runScan() }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isBusy)
        } else {
            HStack(spacing: 8) {
                Button("보존") { model.toggleSimulatorProtection(device) }
                    .buttonStyle(.bordered)
                Button("삭제 검토…") { model.prepareCleanup(device) }
                    .buttonStyle(.bordered)
            }
            .controlSize(.regular)
            .disabled(model.isBusy)
        }
    }

    private var statusText: String {
        if device.isBooted { return "실행 중" }
        if model.hasUnresolvedSimulatorKeepEntries { return "기존 보존 목록 미확인 · 삭제 차단" }
        if model.simulatorKeepUUIDs.contains(device.uuid.uppercased()) { return "보존됨" }
        if !device.hasSupportedCleanupRecipe { return "정리 recipe 미확인 · 삭제 차단" }
        if device.measureStatus == "timed_out" { return "측정 보류" }
        return device.state
    }
}
