import AppKit
import SwiftUI

struct CleanupPage: View {
    @EnvironmentObject private var model: ScanModel
    @State private var selectedKey: String?

    var body: some View {
        Group {
            if let storage = model.storage {
                InspectorSplitLayout {
                    CleanupSelectionList(storage: storage, selection: $selectedKey)
                } detail: {
                    Group {
                        if let record = selectedRecord(in: storage) {
                            CleanupInspectorPane(item: record.item, mode: record.mode)
                        } else {
                            ModernEmptyState(
                                symbol: "sidebar.right",
                                title: "항목을 선택하세요",
                                message: "왼쪽 목록에서 확인할 항목을 선택하세요."
                            )
                        }
                    }
                }
                .onAppear {
                    repairSelection(in: storage)
                }
                .onChange(of: selectionFingerprint(for: storage)) { _ in
                    repairSelection(in: storage)
                }
            } else {
                ModernEmptyState(symbol: "trash", title: "검사 결과가 없습니다", message: "지금 검사를 실행해 정리 후보를 찾으세요.")
            }
        }
    }

    private func selectedRecord(in storage: StorageSnapshot) -> (item: StorageItem, mode: ModernStorageRowMode)? {
        guard let selectedKey else { return nil }
        if let item = storage.cleanupCandidates.first(where: {
            selectionKey(for: $0, mode: .cleanup) == selectedKey
        }) {
            return (item, .cleanup)
        }
        if let item = storage.reviewCandidates.first(where: {
            selectionKey(for: $0, mode: .protected) == selectedKey
        }) {
            return (item, .protected)
        }
        return nil
    }

    private func repairSelection(in storage: StorageSnapshot) {
        let candidates = storage.cleanupCandidates.map {
            selectionKey(for: $0, mode: .cleanup)
        } + storage.reviewCandidates.map {
            selectionKey(for: $0, mode: .protected)
        }
        selectedKey = WorkspaceSelectionKey.repairedSelection(
            current: selectedKey,
            candidates: candidates
        )
    }

    private func selectionFingerprint(for storage: StorageSnapshot) -> String {
        let cleanup = storage.cleanupCandidates.map {
            selectionKey(for: $0, mode: .cleanup) + ":" + $0.measureStatus
        }
        let protected = storage.reviewCandidates.map {
            selectionKey(for: $0, mode: .protected) + ":" + $0.measureStatus
        }
        return (cleanup + protected).joined(separator: "|")
    }
}

struct CleanupSelectionList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(storage.cleanupCandidates) { item in
                    CleanupSelectionRow(item: item, mode: .cleanup)
                        .tag(selectionKey(for: item, mode: .cleanup))
                        .contextMenu {
                            Button { model.revealStorageItem(item) } label: {
                                Label("Finder에서 보기", systemImage: "folder")
                            }
                            Button { model.copyGuide(for: item) } label: {
                                Label("가이드 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                }
            } header: {
                InspectorListHeader(
                    title: "정리 후보",
                    subtitle: "미리보기와 개별 승인을 거칩니다.",
                    value: "논리 \(storage.reclaimableText)"
                )
            }

            Section {
                ForEach(storage.reviewCandidates) { item in
                    CleanupSelectionRow(item: item, mode: .protected)
                        .tag(selectionKey(for: item, mode: .protected))
                        .contextMenu {
                            Button { model.revealStorageItem(item) } label: {
                                Label("Finder에서 보기", systemImage: "folder")
                            }
                            Button { model.copyGuide(for: item) } label: {
                                Label("가이드 복사", systemImage: "doc.on.clipboard")
                            }
                        }
                }
            } header: {
                InspectorListHeader(
                    title: "보호 및 확인",
                    subtitle: "기록과 내부 DB는 자동 정리하지 않습니다.",
                    value: storage.reviewText
                )
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("공간 정리 항목")
    }
}

struct CleanupSelectionRow: View {
    let item: StorageItem
    let mode: ModernStorageRowMode

    var body: some View {
        HStack(spacing: 10) {
            NativeSourceIcon(item: item, fallbackSymbol: rowSymbol)
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
            Spacer(minLength: 12)
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

    private var rowSymbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "rectangle.stack.badge.play"
        }
        if item.label.localizedCaseInsensitiveContains("cache") {
            return "folder.badge.gearshape"
        }
        return "arrow.triangle.2.circlepath"
    }
}

struct CleanupInspectorPane: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let mode: ModernStorageRowMode

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top, spacing: 12) {
                        NativeSourceIcon(item: item, fallbackSymbol: inspectorSymbol)
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

                    Label(statusTitle, systemImage: statusSymbol)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(statusColor)

                    Divider()

                    InspectorTextSection(title: "판단") {
                        Text(item.note.isEmpty ? item.action : item.note)
                    }

                    if !item.action.isEmpty && item.action != item.note {
                        InspectorTextSection(title: mode == .cleanup ? "정리 전 확인" : "권장 조치") {
                            Text(item.action)
                        }
                    }

                    InspectorTextSection(title: "경로") {
                        Text(item.path)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if mode == .cleanup && !isMeasurementDeferred {
                        Text("정리 검토를 누르면 실행 중인 앱과 실제 삭제 대상을 다시 확인합니다. 승인 전에는 삭제하지 않습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            VStack(alignment: .trailing, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        finderButton
                        copyGuideButton
                    }

                    VStack(alignment: .trailing, spacing: 8) {
                        finderButton
                        copyGuideButton
                    }
                }

                if mode == .cleanup {
                    Button(action: performPrimaryAction) {
                        Label(primaryTitle, systemImage: primarySymbol)
                            .frame(minWidth: 180)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label) 세부 정보")
    }

    private var finderButton: some View {
        Button {
            model.revealStorageItem(item)
        } label: {
            Label("Finder에서 보기", systemImage: "folder")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
    }

    private var copyGuideButton: some View {
        Button {
            model.copyGuide(for: item)
        } label: {
            Label("가이드 복사", systemImage: "doc.on.clipboard")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .fixedSize()
        .help("경로와 정리 가이드 복사")
    }

    private var isMeasurementDeferred: Bool {
        item.measureStatus == "timed_out"
    }

    private var statusTitle: String {
        if isMeasurementDeferred { return "크기 측정이 보류되었습니다" }
        if mode == .protected { return "자동 정리에서 보호됩니다" }
        return "미리보기 후 정리할 수 있습니다"
    }

    private var statusSymbol: String {
        if isMeasurementDeferred { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        return "checkmark.shield"
    }

    private var statusColor: Color {
        isMeasurementDeferred ? .orange : .secondary
    }

    private var primaryTitle: String {
        isMeasurementDeferred ? "다시 측정" : "정리 검토…"
    }

    private var primarySymbol: String {
        isMeasurementDeferred ? "arrow.clockwise" : "trash"
    }

    private var inspectorSymbol: String {
        if isMeasurementDeferred { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        return "arrow.triangle.2.circlepath"
    }

    private func performPrimaryAction() {
        if isMeasurementDeferred {
            model.runScan()
        } else {
            model.prepareCleanup(item)
        }
    }
}

private func selectionKey(for item: StorageItem, mode: ModernStorageRowMode) -> String {
    WorkspaceSelectionKey.cleanup(item, mode: mode.rawValue)
}
