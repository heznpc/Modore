import AppKit
import SwiftUI

struct InventoryInspectorPane: View {
    @EnvironmentObject private var model: ScanModel
    let record: InventoryRecord

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                inspectorContent
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            actionBar
                .padding(14)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch record {
        case .simulator(let device):
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    NativeFormSymbolIcon(
                        symbol: device.isBooted ? "iphone.radiowaves.left.and.right" : "iphone",
                        tint: device.isBooted ? .orange : .secondary
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(device.sizeText)
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                            Text("· \(model.storageSnapshotAgeText)")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Label(simulatorStatus(device), systemImage: simulatorStatusSymbol(device))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(simulatorStatusColor(device))

                Divider()

                InspectorTextSection(title: "Runtime") {
                    Text("\(device.runtime) · \(device.state)")
                }

                InspectorTextSection(title: "기기 식별자") {
                    Text(device.uuid)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                InspectorTextSection(title: model.isSimulatorProtected(device) ? "보존 이유" : "삭제 영향") {
                    Text(simulatorExplanation(device))
                }

                Text("Simulator 기기만 삭제하며 설치된 iOS runtime 자체는 유지합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .application(let item):
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 12) {
                    NativeSourceIcon(item: item, fallbackSymbol: "app")
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.label)
                            .font(.title3.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 5) {
                            Text(item.sizeText)
                                .font(.body.weight(.medium))
                                .monospacedDigit()
                            Text("· \(model.storageSnapshotAgeText)")
                                .font(.caption)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Label(
                    item.canCleanup ? "미리보기 후 휴지통으로 이동할 수 있습니다" : "자동 제거 대상이 아닙니다",
                    systemImage: item.canCleanup ? "checkmark.shield" : "lock.shield"
                )
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)

                Divider()

                InspectorTextSection(title: "판단") {
                    Text(item.note.isEmpty ? item.action : item.note)
                }

                if !item.action.isEmpty && item.action != item.note {
                    InspectorTextSection(title: "권장 조치") {
                        Text(item.action)
                    }
                }

                InspectorTextSection(title: "경로") {
                    Text(item.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if item.canCleanup {
                    Text("제거 미리보기에서 앱 본체와 bundle ID에 정확히 귀속되는 사용자 데이터만 다시 확인합니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        switch record {
        case .simulator(let device):
            VStack(alignment: .trailing, spacing: 8) {
                if !device.isBooted {
                    Button {
                        model.toggleSimulatorProtection(device)
                    } label: {
                        Label(
                            model.simulatorKeepNames.contains(device.name) ? "보존 해제" : "보존",
                            systemImage: model.simulatorKeepNames.contains(device.name) ? "lock.open" : "lock"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }

                if device.measureStatus == "timed_out" {
                    Button {
                        model.runScan()
                    } label: {
                        Label("다시 측정", systemImage: "arrow.clockwise")
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                } else if canDelete(device) {
                    Button(role: .destructive) {
                        model.prepareCleanup(device)
                    } label: {
                        Label("삭제 검토…", systemImage: "trash")
                            .frame(minWidth: 170)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                }
            }

        case .application(let item):
            VStack(alignment: .trailing, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        applicationFinderButton(item)
                        applicationCopyButton(item)
                    }
                    VStack(alignment: .trailing, spacing: 8) {
                        applicationFinderButton(item)
                        applicationCopyButton(item)
                    }
                }

                if item.canCleanup {
                    Button(role: .destructive) {
                        model.prepareCleanup(item)
                    } label: {
                        Label("제거 검토…", systemImage: "trash")
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func applicationFinderButton(_ item: StorageItem) -> some View {
        Button {
            model.revealStorageItem(item)
        } label: {
            Label("Finder에서 보기", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    private func applicationCopyButton(_ item: StorageItem) -> some View {
        Button {
            model.copyGuide(for: item)
        } label: {
            Label("정보 복사", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    private func canDelete(_ device: SimulatorDevice) -> Bool {
        device.state == "Shutdown"
            && device.measureStatus != "timed_out"
            && !device.cleanupID.isEmpty
            && !model.isSimulatorProtected(device)
    }

    private func simulatorStatus(_ device: SimulatorDevice) -> String {
        if device.isBooted { return "현재 실행 중이라 삭제할 수 없습니다" }
        if model.simulatorKeepNames.contains(device.name) { return "보존 목록에 포함된 기기입니다" }
        if device.measureStatus == "timed_out" { return "크기 측정이 보류되었습니다" }
        if device.state == "Shutdown" { return "미리보기 후 삭제할 수 있습니다" }
        return "현재 상태에서는 삭제할 수 없습니다"
    }

    private func simulatorStatusSymbol(_ device: SimulatorDevice) -> String {
        if device.isBooted || model.simulatorKeepNames.contains(device.name) { return "lock.shield" }
        if device.measureStatus == "timed_out" { return "hourglass" }
        return "checkmark.shield"
    }

    private func simulatorStatusColor(_ device: SimulatorDevice) -> Color {
        if device.isBooted || device.measureStatus == "timed_out" { return .orange }
        return .secondary
    }

    private func simulatorExplanation(_ device: SimulatorDevice) -> String {
        if device.isBooted {
            return "현재 Booted 상태입니다. 실행 중인 기기는 보존 해제나 삭제를 할 수 없습니다."
        }
        if model.simulatorKeepNames.contains(device.name) {
            return "사용자가 보존하도록 지정했습니다. 보존을 해제하기 전에는 삭제 미리보기를 열 수 없습니다."
        }
        if !device.protectionReason.isEmpty {
            return device.protectionReason
        }
        return "선택한 UUID의 가상 기기와 기기 데이터만 삭제 대상으로 확인합니다."
    }
}
