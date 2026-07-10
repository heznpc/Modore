import AppKit
import SwiftUI

enum InventoryRecord {
    case simulator(SimulatorDevice)
    case application(StorageItem)
}
struct InventoryPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selectedKey: String?

    var body: some View {
        Group {
            if let storage = model.storage {
                InspectorSplitLayout {
                    InventorySelectionList(storage: storage, selection: $selectedKey)
                } detail: {
                    if let record = selectedRecord(in: storage) {
                        InventoryInspectorPane(record: record)
                    } else {
                        ModernEmptyState(
                            symbol: "sidebar.right",
                            title: "항목을 선택하세요",
                            message: "앱이나 Simulator를 선택하면 보존·제거 조건을 보여드립니다."
                        )
                    }
                }
                .onAppear {
                    repairSelection(in: storage)
                }
                .onChange(of: selectionFingerprint(for: storage)) { _ in
                    repairSelection(in: storage)
                }
            } else {
                ModernEmptyState(
                    symbol: "square.grid.2x2",
                    title: "앱 정보가 없습니다",
                    message: "검사를 실행해 설치 앱과 Simulator를 확인하세요."
                )
            }
        }
    }

    private func selectedRecord(in storage: StorageSnapshot) -> InventoryRecord? {
        guard let selectedKey else { return nil }
        if let device = storage.simulatorDevices.first(where: {
            WorkspaceSelectionKey.simulator($0) == selectedKey
        }) {
            return .simulator(device)
        }
        if let item = storage.applications.first(where: {
            WorkspaceSelectionKey.application($0) == selectedKey
        }) {
            return .application(item)
        }
        return nil
    }

    private func repairSelection(in storage: StorageSnapshot) {
        let candidates = storage.simulatorDevices.map(WorkspaceSelectionKey.simulator)
            + storage.applications.map(WorkspaceSelectionKey.application)
        selectedKey = WorkspaceSelectionKey.repairedSelection(
            current: selectedKey,
            candidates: candidates
        )
    }

    private func selectionFingerprint(for storage: StorageSnapshot) -> String {
        let simulators = storage.simulatorDevices.map {
            WorkspaceSelectionKey.simulator($0) + ":" + $0.state + ":" + $0.measureStatus
        }
        let applications = storage.applications.map {
            WorkspaceSelectionKey.application($0) + ":" + $0.measureStatus
        }
        return (simulators + applications).joined(separator: "|")
    }
}

struct InventorySelectionList: View {
    let storage: StorageSnapshot
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !storage.simulatorDevices.isEmpty {
                Section {
                    ForEach(storage.simulatorDevices) { device in
                        InventorySimulatorSelectionRow(device: device)
                            .tag(WorkspaceSelectionKey.simulator(device))
                    }
                } header: {
                    InspectorListHeader(
                        title: "Simulator",
                        subtitle: "실행 중이거나 보존한 기기는 삭제할 수 없습니다.",
                        value: storage.simulatorText
                    )
                }
            }

            Section {
                ForEach(storage.applications) { item in
                    InventoryApplicationSelectionRow(item: item)
                        .tag(WorkspaceSelectionKey.application(item))
                }
            } header: {
                InspectorListHeader(
                    title: "설치 앱",
                    subtitle: "정확한 bundle ID로 확인된 항목만 제거 대상으로 봅니다.",
                    value: storage.applicationsText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("앱 및 Simulator 항목")
    }
}

struct InventorySimulatorSelectionRow: View {
    @EnvironmentObject private var model: ScanModel
    let device: SimulatorDevice

    var body: some View {
        HStack(spacing: 10) {
            NativeFormSymbolIcon(
                symbol: device.isBooted ? "iphone.radiowaves.left.and.right" : "iphone",
                tint: device.isBooted ? .orange : .secondary
            )
            VStack(alignment: .leading, spacing: 2) {
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
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(device.name), \(statusText), \(device.sizeText)")
    }

    private var statusText: String {
        if device.isBooted { return "실행 중" }
        if model.simulatorKeepNames.contains(device.name) { return "보존" }
        return device.state
    }
}

struct InventoryApplicationSelectionRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 10) {
            NativeSourceIcon(item: item, fallbackSymbol: "app")
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.path)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(item.sizeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.label), \(item.sizeText)")
    }
}
