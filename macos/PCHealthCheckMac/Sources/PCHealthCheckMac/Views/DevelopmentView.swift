import AppKit
import SwiftUI

enum DevelopmentRecord {
    case runtime(RuntimeSignal)
    case asset(StorageItem)
}

struct DevelopmentPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selectedKey: String?

    var body: some View {
        Group {
            if let storage = model.storage {
                InspectorSplitLayout {
                    DevelopmentSelectionList(storage: storage, selection: $selectedKey)
                } detail: {
                    if let record = selectedRecord(in: storage) {
                        DevelopmentInspectorPane(record: record)
                    } else {
                        ModernEmptyState(
                            symbol: "sidebar.right",
                            title: "항목을 선택하세요",
                            message: "실행 신호나 개발 자산을 선택하면 보존 이유를 보여드립니다."
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
                    symbol: "hammer",
                    title: "개발 환경 정보가 없습니다",
                    message: "검사를 실행해 SDK와 runtime을 확인하세요."
                )
            }
        }
    }

    private func selectedRecord(in storage: StorageSnapshot) -> DevelopmentRecord? {
        guard let selectedKey else { return nil }
        if let signal = storage.runtimeSignals.first(where: {
            WorkspaceSelectionKey.runtime($0) == selectedKey
        }) {
            return .runtime(signal)
        }
        if let item = storage.developerToolchains.first(where: {
            WorkspaceSelectionKey.developmentAsset($0) == selectedKey
        }) {
            return .asset(item)
        }
        return nil
    }

    private func repairSelection(in storage: StorageSnapshot) {
        let candidates = storage.runtimeSignals.map(WorkspaceSelectionKey.runtime)
            + storage.developerToolchains.map(WorkspaceSelectionKey.developmentAsset)
        selectedKey = WorkspaceSelectionKey.repairedSelection(
            current: selectedKey,
            candidates: candidates
        )
    }

    private func selectionFingerprint(for storage: StorageSnapshot) -> String {
        let runtime = storage.runtimeSignals.map {
            WorkspaceSelectionKey.runtime($0) + ":" + $0.risk + ":" + String($0.count)
        }
        let assets = storage.developerToolchains.map {
            WorkspaceSelectionKey.developmentAsset($0) + ":" + $0.measureStatus
        }
        return (runtime + assets).joined(separator: "|")
    }
}

struct DevelopmentSelectionList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            if !storage.runtimeSignals.isEmpty {
                Section {
                    ForEach(storage.runtimeSignals) { signal in
                        DevelopmentRuntimeSelectionRow(signal: signal)
                            .tag(WorkspaceSelectionKey.runtime(signal))
                    }
                } header: {
                    InspectorListHeader(
                        title: "현재 실행 신호",
                        subtitle: "공간을 다시 채울 수 있는 실행원을 먼저 확인합니다.",
                        value: "\(storage.runtimeSignals.count)종"
                    )
                }
            }

            Section {
                ForEach(storage.developerToolchains) { item in
                    DevelopmentAssetSelectionRow(item: item)
                        .tag(WorkspaceSelectionKey.developmentAsset(item))
                        .contextMenu {
                            Button { model.revealStorageItem(item) } label: {
                                Label("Finder에서 보기", systemImage: "folder")
                            }
                            Button { model.copyGuide(for: item) } label: {
                                Label("정보 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                }
            } header: {
                InspectorListHeader(
                    title: "설치된 개발 자산",
                    subtitle: "부모 경로와 겹치는 하위 구성요소는 중복 합산하지 않습니다.",
                    value: storage.developerText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("개발 환경 항목")
    }
}

struct DevelopmentRuntimeSelectionRow: View {
    let signal: RuntimeSignal

    var body: some View {
        HStack(spacing: 10) {
            NativeStatusGlyph(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(signal.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(signal.note)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            Text(signal.countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(signal.label), \(signal.countText)")
    }

    private var symbol: String {
        switch signal.risk {
        case "warning": return "exclamationmark"
        case "safe": return "checkmark"
        default: return "info.circle"
        }
    }

    private var tint: Color {
        signal.risk == "warning" ? .orange : .secondary
    }
}

struct DevelopmentAssetSelectionRow: View {
    let item: StorageItem

    var body: some View {
        HStack(spacing: 10) {
            NativeSourceIcon(item: item, fallbackSymbol: symbol)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(item.note.isEmpty ? item.action : item.note)
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

    private var symbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        let value = (item.kind + " " + item.label).lowercased()
        if value.contains("android") { return "shippingbox" }
        if value.contains("simulator") || value.contains("xcode") { return "hammer" }
        return "wrench.and.screwdriver"
    }
}
