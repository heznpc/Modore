import AppKit
import SwiftUI

struct CleanupInspectorPane: View {
    let item: StorageItem
    let mode: ModernStorageRowMode

    var body: some View {
        VStack(spacing: 0) {
            CleanupInspectorDetails(item: item, presentation: presentation)
            Divider()
            CleanupInspectorActions(item: item, presentation: presentation)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.label) 세부 정보")
    }

    private var presentation: CleanupInspectorPresentation {
        CleanupInspectorPresentation(item: item, mode: mode)
    }
}

struct CleanupInspectorDetails: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let presentation: CleanupInspectorPresentation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Label(presentation.statusTitle, systemImage: presentation.statusSymbol)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(presentation.statusColor)
                Divider()
                InspectorTextSection(title: "판단") {
                    Text(item.note.isEmpty ? item.action : item.note)
                }
                if !item.action.isEmpty && item.action != item.note {
                    InspectorTextSection(title: presentation.mode == .cleanup ? "정리 전 확인" : "권장 조치") {
                        Text(item.action)
                    }
                }
                InspectorTextSection(title: "경로") {
                    Text(item.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if presentation.mode == .cleanup && !presentation.isMeasurementDeferred {
                    Text("정리 검토를 누르면 실행 중인 앱과 실제 삭제 대상을 다시 확인합니다. 승인 전에는 삭제하지 않습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeSourceIcon(item: item, fallbackSymbol: presentation.inspectorSymbol)
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
    }
}

struct CleanupInspectorActions: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let presentation: CleanupInspectorPresentation

    var body: some View {
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
            if presentation.mode == .cleanup {
                Button(action: performPrimaryAction) {
                    Label(presentation.primaryTitle, systemImage: presentation.primarySymbol)
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

    private func performPrimaryAction() {
        if presentation.isMeasurementDeferred {
            model.runScan()
        } else {
            model.prepareCleanup(item)
        }
    }
}

struct CleanupInspectorPresentation {
    let item: StorageItem
    let mode: ModernStorageRowMode

    var isMeasurementDeferred: Bool { item.measureStatus == "timed_out" }
    var statusTitle: String {
        if isMeasurementDeferred { return "크기 측정이 보류되었습니다" }
        if mode == .protected { return "자동 정리에서 보호됩니다" }
        return "미리보기 후 정리할 수 있습니다"
    }
    var statusSymbol: String {
        if isMeasurementDeferred { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        return "checkmark.shield"
    }
    var statusColor: Color { isMeasurementDeferred ? .orange : .secondary }
    var primaryTitle: String { isMeasurementDeferred ? "다시 측정" : "정리 검토…" }
    var primarySymbol: String { isMeasurementDeferred ? "arrow.clockwise" : "trash" }
    var inspectorSymbol: String {
        if isMeasurementDeferred { return "hourglass" }
        if mode == .protected { return "lock.shield" }
        return "arrow.triangle.2.circlepath"
    }
}

func selectionKey(for item: StorageItem, mode: ModernStorageRowMode) -> String {
    WorkspaceSelectionKey.cleanup(item, mode: mode.rawValue)
}
