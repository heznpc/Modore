import AppKit
import SwiftUI

enum ModernStorageRowMode: String {
    case cleanup
    case protected
    case developer
}
struct ModernStorageRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem
    let mode: ModernStorageRowMode

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
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
            Spacer(minLength: 16)
            Text(item.sizeText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button(primaryTitle, action: performPrimaryAction)
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .frame(minWidth: 72)
                .disabled(model.isBusy)
                .help(primaryHelp)
                .accessibilityLabel("\(item.label) \(primaryAccessibilityAction)")
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("\(item.note.isEmpty ? item.action : item.note)\n\(item.path)")
        .contextMenu {
            Button { model.revealStorageItem(item) } label: {
                Label("Finder에서 보기", systemImage: "folder")
            }
            Button { model.copyGuide(for: item) } label: {
                Label("가이드 복사", systemImage: "doc.on.clipboard")
            }
        }
    }

    private var opensCleanupPreview: Bool {
        mode == .cleanup && item.canCleanup
    }

    private var isMeasurementDeferred: Bool {
        mode == .cleanup && item.measureStatus == "timed_out"
    }

    private var primaryTitle: String {
        if isMeasurementDeferred { return "다시 측정" }
        return opensCleanupPreview ? "검토…" : "보기"
    }

    private var primaryHelp: String {
        if isMeasurementDeferred { return "저장공간 다시 검사" }
        return opensCleanupPreview ? "정리 미리보기 열기" : "Finder에서 보기"
    }

    private var primaryAccessibilityAction: String {
        if isMeasurementDeferred { return "다시 측정" }
        return opensCleanupPreview ? "정리 검토" : "Finder에서 보기"
    }

    private func performPrimaryAction() {
        if isMeasurementDeferred {
            model.runScan()
        } else if opensCleanupPreview {
            model.prepareCleanup(item)
        } else {
            model.revealStorageItem(item)
        }
    }

    private var rowSymbol: String {
        if isMeasurementDeferred {
            return "hourglass"
        }
        if item.label.localizedCaseInsensitiveContains("cache") {
            return "folder.badge.gearshape"
        }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "rectangle.stack.badge.play"
        }
        switch mode {
        case .cleanup: return "arrow.triangle.2.circlepath"
        case .protected: return "lock.shield"
        case .developer: return "wrench.and.screwdriver"
        }
    }
}
