import SwiftUI

struct StatusPage: View {
    @EnvironmentObject private var model: ScanModel
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onOpenSecurity: () -> Void
    let onOpenActivity: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            pageContent(at: context.date)
        }
    }

    @ViewBuilder
    private func pageContent(at date: Date) -> some View {
        Group {
            if let storage = model.storage {
                Form {
                    Section {
                        StatusStorageSummary(
                            storage: storage,
                            change: model.storageChange,
                            snapshotNeedsRefresh: model.storageSnapshotNeedsRefresh(at: date)
                        )
                    }

                    if let newer = model.newerStorageHistoryEntry {
                        Section {
                            StatusNoticeRow(
                                symbol: "clock.badge.exclamationmark",
                                title: "이 화면보다 최신 기록이 있습니다",
                                detail: String(
                                    format: "활동에 %@의 여유 공간 기록(%.1fGB)이 있습니다. 세부 항목을 섞지 않도록 이 화면은 이전 전체 검사에 고정되어 있으니 지금 다시 검사하세요.",
                                    newer.capturedAt.formatted(date: .abbreviated, time: .shortened),
                                    newer.freeGB
                                ),
                                tint: .secondary
                            )
                        }
                    } else if model.isStorageSnapshotStale(at: date) {
                        Section {
                            StatusNoticeRow(
                                symbol: "clock",
                                title: "현재 결과가 오래되었습니다",
                                detail: "\(model.storageSnapshotAgeText) 결과입니다. 새 검사 전까지 정리 가능 용량이 달라질 수 있습니다.",
                                tint: .secondary
                            )
                        }
                    }

                    StatusChangeSection(
                        change: model.storageChange,
                        onOpenStorage: onOpenStorage,
                        onOpenActivity: onOpenActivity
                    )

                    Section("다음 행동") {
                        StatusActionRow(
                            symbol: "trash",
                            title: "정리 가능한 항목",
                            detail: "미리보기 가능한 캐시·임시 파일의 대상 점유 추정입니다.",
                            value: storage.reclaimableText,
                            actionTitle: "항목 보기"
                        ) {
                            onOpenStorage(.cleanup)
                        }

                        if !storage.attentionRuntimeSignals.isEmpty {
                            StatusActionRow(
                                symbol: "hammer",
                                title: "다시 공간을 채우는 작업",
                                detail: "실행 중인 개발 도구와 자동화 작업을 확인합니다.",
                                value: "\(storage.attentionRuntimeSignals.count)종",
                                actionTitle: "개발 보기"
                            ) {
                                onOpenStorage(.development)
                            }
                        }

                        if model.securityAttentionCount > 0 {
                            StatusActionRow(
                                symbol: "lock.shield",
                                title: "보안 확인 필요",
                                detail: model.summary?.message ?? "확인할 진단 결과가 있습니다.",
                                value: "\(model.securityAttentionCount)건",
                                actionTitle: "보안 보기"
                            ) {
                                onOpenSecurity()
                            }
                        }

                        if !model.storageWatchEnabled {
                            StatusActionRow(
                                symbol: "clock.arrow.circlepath",
                                title: "급감 감시 꺼짐",
                                detail: "감시를 켜면 여유 공간만 로컬에 기록하고 급격한 감소를 알립니다.",
                                value: "자동 삭제 없음",
                                actionTitle: "활동 보기"
                            ) {
                                onOpenActivity()
                            }
                        }
                    }
                }
                .macSettingsFormStyle()
            } else {
                ModernEmptyState(
                    symbol: "internaldrive",
                    title: "아직 검사 결과가 없습니다",
                    message: "검사가 끝나면 현재 저장공간과 보안 상태가 여기에 표시됩니다."
                )
            }
        }
    }
}

private struct StatusStorageSummary: View {
    let storage: StorageSnapshot
    let change: StorageChangeSummary?
    let snapshotNeedsRefresh: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatusStorageHeader(
                freeGB: storage.freeGB,
                changeDescription: changeDescription,
                snapshotNeedsRefresh: snapshotNeedsRefresh
            )
            StatusStorageMeter(storage: storage, snapshotNeedsRefresh: snapshotNeedsRefresh)
        }
        .padding(.vertical, 8)
    }

    private var changeDescription: String {
        guard let change else { return "이 검사부터 변화 비교를 시작합니다." }
        if change.consumedGB >= 0.05 {
            return String(format: "직전 검사보다 %.1fGB 줄었습니다.", change.consumedGB)
        }
        if change.recoveredGB >= 0.05 {
            return String(format: "직전 검사보다 %.1fGB 늘었습니다.", change.recoveredGB)
        }
        return "직전 검사와 거의 같습니다."
    }

}

private struct StatusStorageHeader: View {
    @EnvironmentObject private var model: ScanModel
    let freeGB: Double
    let changeDescription: String
    let snapshotNeedsRefresh: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(freeSpaceTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .monospacedDigit()
                Text(changeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 20)
            VStack(alignment: .trailing, spacing: 3) {
                Text("시동 볼륨")
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 60)) { _ in
                    Text(model.storageSnapshotAgeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var freeSpaceTitle: String {
        let value = String(format: "%.1fGB", freeGB)
        return snapshotNeedsRefresh ? "검사 당시 \(value) 사용 가능" : "\(value) 사용 가능"
    }
}

private struct StatusStorageMeter: View {
    let storage: StorageSnapshot
    let snapshotNeedsRefresh: Bool

    var body: some View {
        ProgressView(value: min(max(storage.usePercent, 0), 100), total: 100)
            .progressViewStyle(.linear)
            .tint(storage.risk == "danger" ? .red : .secondary)
        HStack {
            Text(snapshotNeedsRefresh
                ? "검사 당시 파일 시스템 사용률 \(storage.usePercent, specifier: "%.0f")%"
                : "파일 시스템 사용률 \(storage.usePercent, specifier: "%.0f")%")
            Spacer()
            Text("사용 중 \(storage.usedGB, specifier: "%.1f")GB")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()

        Text("볼륨 크기 \(storage.totalGB, specifier: "%.1f")GB. APFS 공유 공간·스냅샷·예약 영역 때문에 ‘사용 중’과 ‘사용 가능’의 합은 볼륨 크기와 다를 수 있습니다.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StatusChangeSection: View {
    let change: StorageChangeSummary?
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onOpenActivity: () -> Void

    var body: some View {
        Section("최근 변화") {
            if let change, let largest = change.largestChanges.first {
                StatusActionRow(
                    symbol: largest.deltaGB > 0 ? "arrow.up.right" : "arrow.down.right",
                    title: largest.label,
                    detail: changeDetail(largest),
                    value: String(format: "%+.1fGB", largest.deltaGB),
                    actionTitle: "확인"
                ) {
                    onOpenStorage(largest.category == "developer" ? .development : .cleanup)
                }

                if change.unattributedConsumedGB >= 0.1 {
                    StatusNoticeRow(
                        symbol: "questionmark.circle",
                        title: "추적 밖에서 사용된 공간",
                        detail: "APFS snapshot, swap 또는 접근이 제한된 영역일 수 있습니다.",
                        value: String(format: "%.1fGB", change.unattributedConsumedGB),
                        tint: .secondary
                    )
                }
            } else {
                StatusNoticeRow(
                    symbol: "record.circle",
                    title: "비교할 이전 검사가 없습니다",
                    detail: "다음 검사부터 무엇이 늘고 줄었는지 비교합니다.",
                    tint: .secondary
                )
            }

            Button(action: onOpenActivity) {
                Label("전체 변화 기록 보기", systemImage: "clock.arrow.circlepath")
            }
            .buttonStyle(.link)
        }
    }

    private func changeDetail(_ item: StorageItemChange) -> String {
        String(format: "경로 점유 추정: 직전 %.1fGB · 현재 %.1fGB", item.beforeGB, item.afterGB)
    }
}

private struct StatusActionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let value: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 6) {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct StatusNoticeRow: View {
    let symbol: String
    let title: String
    let detail: String
    var value: String = ""
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !value.isEmpty {
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 5)
    }
}
