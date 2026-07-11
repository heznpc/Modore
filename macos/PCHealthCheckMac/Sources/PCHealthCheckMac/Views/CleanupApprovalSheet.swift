import SwiftUI

struct CleanupApprovalSheet: View {
    @EnvironmentObject private var model: ScanModel
    let preview: CleanupPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            CleanupApprovalHeader(preview: preview)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    CleanupApprovalNotices(
                        preview: preview,
                        sizeChangeNotice: sizeChangeNotice,
                        runningProcesses: runningProcesses
                    )
                    CleanupTargets(preview: preview)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("정리 세부 정보")
                .accessibilityValue(accessibilityDetailText)
            }
            Divider()
            CleanupApprovalActions(preview: preview)
        }
        .padding(24)
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 760, minHeight: 320, idealHeight: 440, maxHeight: 640)
        .interactiveDismissDisabled(model.cleanupInFlight)
    }

    private var sizeChangeNotice: String? {
        let item = model.storage?.cleanupCandidates.first(where: {
            $0.cleanupID == preview.recipeID
        })
        return CleanupPresentation.sizeChangeNotice(
            snapshotAge: model.storageSnapshotAgeText,
            scannedSize: item?.sizeText,
            previewSize: preview.estimatedText
        )
    }

    private var runningProcesses: [CleanupProcessDisplay] {
        CleanupPresentation.processDisplays(from: preview.runningProcesses)
    }

    private var accessibilityDetailText: String {
        var parts: [String] = []
        if let sizeChangeNotice { parts.append(sizeChangeNotice) }
        if !preview.blockedReason.isEmpty { parts.append(preview.blockedReason) }
        if !runningProcesses.isEmpty {
            parts.append("실행 중인 항목: " + runningProcesses.map(\.name).joined(separator: ", "))
        }
        if !preview.targets.isEmpty {
            parts.append("정리 대상: " + preview.targets.joined(separator: ", "))
        }
        if !preview.warning.isEmpty { parts.append(preview.warning) }
        return parts.joined(separator: ". ")
    }
}

private struct CleanupApprovalHeader: View {
    let preview: CleanupPreview

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: preview.canExecute ? "trash" : "pause.circle")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(preview.label)
                    .font(.title3.weight(.semibold))
                Text(preview.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("현재 대상 점유 추정")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(preview.estimatedText)
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }
}

private struct CleanupApprovalNotices: View {
    let preview: CleanupPreview
    let sizeChangeNotice: String?
    let runningProcesses: [CleanupProcessDisplay]

    var body: some View {
        if let sizeChangeNotice {
            Label(sizeChangeNotice, systemImage: "clock.arrow.circlepath")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        if !preview.blockedReason.isEmpty {
            Label(preview.blockedReason, systemImage: "pause.circle")
                .foregroundStyle(.secondary)
        }
        if !runningProcesses.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("감지된 실행 항목")
                    .font(.headline)
                ForEach(Array(runningProcesses.enumerated()), id: \.offset) { _, process in
                    Label(process.name, systemImage: "app")
                        .font(.callout)
                        .lineLimit(2)
                        .help(process.rawCommand)
                        .accessibilityLabel("실행 중인 항목: \(process.name)")
                        .accessibilityValue(process.rawCommand)
                }
            }
        }
    }
}

private struct CleanupTargets: View {
    let preview: CleanupPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("정리 대상")
                .font(.headline)
            ForEach(preview.targets, id: \.self) { target in
                Text(target)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("정리 대상 경로: \(target)")
            }
            if !preview.warning.isEmpty {
                Text(preview.warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("정리 대상과 주의사항")
    }
}

private struct CleanupApprovalActions: View {
    @EnvironmentObject private var model: ScanModel
    let preview: CleanupPreview

    var body: some View {
        HStack {
            Label("AI 호출 없음 · 고정된 로컬 레시피", systemImage: "lock.shield")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("취소", role: .cancel) { model.dismissCleanupPreview() }
                .disabled(model.cleanupInFlight)
                .keyboardShortcut(.cancelAction)
            retryButton
            executeButton
        }
    }

    @ViewBuilder
    private var retryButton: some View {
        if preview.status == "blocked" {
            Button {
                model.retryCleanupPreview(preview)
            } label: {
                if model.cleanupInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Label("다시 확인", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.cleanupInFlight)
        }
    }

    @ViewBuilder
    private var executeButton: some View {
        if preview.canExecute {
            Button(role: .destructive) {
                model.executeCleanup(preview)
            } label: {
                if model.cleanupInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Label(executeLabel, systemImage: "trash")
                }
            }
            .disabled(model.cleanupInFlight)
            .tint(.red)
        }
    }

    private var executeLabel: String {
        switch preview.actionMode {
        case "trash": return "\(preview.estimatedText) 휴지통으로 이동"
        case "simulator": return "\(preview.estimatedText) Simulator 삭제"
        default: return "\(preview.estimatedText) 정리"
        }
    }
}
