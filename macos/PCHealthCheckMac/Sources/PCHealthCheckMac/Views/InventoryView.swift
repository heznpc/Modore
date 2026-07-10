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

struct NativeSourceIcon: View {
    let item: StorageItem
    let fallbackSymbol: String

    var body: some View {
        Group {
            if let applicationURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: applicationURL.path))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 36, height: 36)
            } else {
                NativeFormSymbolIcon(symbol: fallbackSymbol, tint: .secondary)
            }
        }
    }

    private var applicationURL: URL? {
        if item.path.hasSuffix(".app"), FileManager.default.fileExists(atPath: item.path) {
            return URL(fileURLWithPath: item.path)
        }

        let label = item.label.lowercased()
        let bundleIdentifier: String?
        if label.contains("chrome") {
            bundleIdentifier = "com.google.Chrome"
        } else if label.contains("claude") {
            bundleIdentifier = "com.anthropic.claudefordesktop"
        } else if label.contains("codex") {
            bundleIdentifier = "com.openai.codex"
        } else {
            bundleIdentifier = nil
        }
        if let bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }

        if label.contains("codex") {
            let candidates = [
                "/Applications/Codex.app",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Codex.app").path,
            ]
            return candidates.first(where: FileManager.default.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
        }
        if label.contains("claude") {
            let candidates = [
                "/Applications/Claude.app",
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Claude.app").path,
            ]
            return candidates.first(where: FileManager.default.fileExists(atPath:)).map(URL.init(fileURLWithPath:))
        }
        return nil
    }
}

struct NativeFormSymbolIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}
