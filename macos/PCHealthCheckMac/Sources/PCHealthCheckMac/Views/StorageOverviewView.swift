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
                        StatusIncidentSummary(
                            assessment: assessment,
                            evidenceTimingNote: model.isStorageSnapshotStale(at: date)
                                ? "\(model.storageSnapshotAgeText) 결과 기준 판단입니다. 새 검사 전에는 현재 상태로 단정하지 않습니다."
                                : nil
                        )
                    } header: {
                        NativeSectionHeader(
                            title: "현재 판단",
                            subtitle: "관찰된 사실과 수집 범위를 기준으로 가장 중요한 상태 하나를 먼저 보여줍니다.",
                            value: assessment.value
                        )
                    }

                    StatusIncidentEvidenceSection(
                        coverage: model.collectionCoverage,
                        storage: storage,
                        change: model.storageChange,
                        securityFinding: model.securityFindings.first,
                        onOpenStorage: onOpenStorage,
                        onOpenSecurity: onOpenSecurity,
                        onOpenActivity: onOpenActivity
                    )

                    Section("예상 영향") {
                        StatusNoticeRow(
                            symbol: "arrow.triangle.branch",
                            title: assessment.impact,
                            detail: "원인을 확정하지 않은 상태에서 프로세스 종료나 파일 삭제를 자동으로 실행하지 않습니다.",
                            tint: assessment.kind == .securityDanger ? .red : .secondary
                        )
                    }

                    Section {
                        StatusStorageSummary(
                            storage: storage,
                            change: model.storageChange,
                            snapshotNeedsRefresh: model.storageSnapshotNeedsRefresh(at: date)
                        )
                    } header: {
                        NativeSectionHeader(
                            title: "현재 자원 상태",
                            subtitle: "사고 판단을 보조하는 시동 볼륨 정보입니다.",
                            value: model.storageSnapshotAgeText
                        )
                    }

                    if !storage.accessIssues.isEmpty {
                        StorageAccessIssuesSection(
                            issues: storage.accessIssues,
                            openSettings: model.openFullDiskAccessSettings
                        )
                    }

                    StatusRecoverySection(
                        assessment: assessment,
                        storage: storage,
                        isBusy: model.isBusy,
                        runScan: model.runScan,
                        onOpenStorage: onOpenStorage,
                        onOpenSecurity: onOpenSecurity,
                        onOpenActivity: onOpenActivity
                    )

                    if let newer = model.newerStorageHistoryEntry {
                        Section("결과 시점") {
                            StatusNoticeRow(
                                symbol: "clock.badge.exclamationmark",
                                title: "이 화면보다 최신 기록이 있습니다",
                                detail: String(
                                    format: "활동에 %@의 여유 공간 기록(%.1fGB)이 있습니다. 전체 검사를 다시 실행하기 전에는 서로 다른 시점의 결과를 섞지 않습니다.",
                                    newer.capturedAt.formatted(date: .abbreviated, time: .shortened),
                                    newer.freeGB
                                ),
                                tint: .secondary
                            )
                        }
                    } else if model.isStorageSnapshotStale(at: date) {
                        Section("결과 시점") {
                            StatusNoticeRow(
                                symbol: "clock",
                                title: "현재 결과가 오래되었습니다",
                                detail: "\(model.storageSnapshotAgeText) 결과입니다. 새 검사 전에는 현재 상태로 단정하지 않습니다.",
                                tint: .secondary
                            )
                        }
                    }
                }
                .macSettingsFormStyle()
            } else if model.summary != nil {
                Form {
                    Section {
                        StatusIncidentSummary(assessment: assessment)
                    } header: {
                        NativeSectionHeader(
                            title: "현재 판단",
                            subtitle: "저장공간 수집 여부와 별개로 완료된 진단 결과를 표시합니다.",
                            value: assessment.value
                        )
                    }

                    Section("관찰 근거") {
                        StatusNavigationRow(
                            symbol: model.collectionCoverage?.complete == true
                                ? "checkmark.shield" : "questionmark.shield",
                            title: "검사 범위",
                            detail: model.collectionCoverage?.complete == true
                                ? "필수 수집기가 모두 응답했습니다."
                                : "완료하지 못한 수집기가 있어 결과를 정상으로 확정하지 않습니다.",
                            value: model.collectionCoverage?.coverageText ?? "기록 없음",
                            action: onOpenSecurity
                        )
                    }

                    Section("예상 영향") {
                        StatusNoticeRow(
                            symbol: "arrow.triangle.branch",
                            title: assessment.impact,
                            detail: "수집되지 않은 값을 0으로 대체하거나 자동 조치를 실행하지 않습니다.",
                            tint: assessment.kind == .securityDanger ? .red : .secondary
                        )
                    }

                    StatusRecoverySection(
                        assessment: assessment,
                        storage: nil,
                        isBusy: model.isBusy,
                        runScan: model.runScan,
                        onOpenStorage: onOpenStorage,
                        onOpenSecurity: onOpenSecurity,
                        onOpenActivity: onOpenActivity
                    )
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

    private var assessment: IncidentAssessment {
        IncidentAssessment.make(content: model.content, storageChange: model.storageChange)
    }
}

private struct StatusIncidentSummary: View {
    let assessment: IncidentAssessment
    var evidenceTimingNote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: assessment.symbol)
                .font(.system(size: 24, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isDanger ? Color.red : Color.secondary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(assessment.title)
                    .font(.title3.weight(.semibold))
                Text(assessment.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let evidenceTimingNote {
                    Label(evidenceTimingNote, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(assessment.title). \(assessment.detail)"
                + (evidenceTimingNote.map { " \($0)" } ?? "")
        )
    }

    private var isDanger: Bool {
        assessment.kind == .securityDanger || assessment.kind == .storageCritical
    }
}

private struct StatusIncidentEvidenceSection: View {
    let coverage: CollectionCoverage?
    let storage: StorageSnapshot
    let change: StorageChangeSummary?
    let securityFinding: ScanFinding?
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onOpenSecurity: () -> Void
    let onOpenActivity: () -> Void

    var body: some View {
        Section {
            StatusNavigationRow(
                symbol: coverage?.complete == true ? "checkmark.shield" : "questionmark.shield",
                title: "검사 범위",
                detail: coverageDetail,
                value: coverage?.coverageText ?? "기록 없음",
                action: onOpenSecurity
            )

            if storage.browserAutomation.verdict != "unknown",
               storage.browserAutomation.verdict != "clear" {
                StatusNavigationRow(
                    symbol: "rectangle.on.rectangle",
                    title: "브라우저 자동화",
                    detail: storage.browserAutomation.note,
                    value: "\(storage.browserAutomation.rootCount)개 루트"
                ) {
                    onOpenStorage(.development)
                }
            }

            if let change {
                StatusNavigationRow(
                    symbol: change.freeDeltaGB < -0.05 ? "arrow.down.right" : "arrow.up.right",
                    title: "직전 검사 이후 변화",
                    detail: changeDetail(change),
                    value: String(format: "%+.1fGB", change.freeDeltaGB),
                    action: onOpenActivity
                )
            }

            if let securityFinding {
                StatusNavigationRow(
                    symbol: securityFinding.level == "danger" ? "exclamationmark.shield" : "info.circle",
                    title: securityFinding.title,
                    detail: securityFinding.detail,
                    value: securityFinding.level == "danger" ? "위험" : "확인 필요",
                    action: onOpenSecurity
                )
            }
        } header: {
            NativeSectionHeader(
                title: "관찰 근거",
                subtitle: "판단에 사용한 실제 수집 범위와 변화 신호입니다.",
                value: "자동 추론 아님"
            )
        }
    }

    private var coverageDetail: String {
        guard let coverage else {
            return "이전 형식의 결과에는 수집 성공 여부가 없습니다. 새 검사가 필요합니다."
        }
        if coverage.complete {
            return "필수 수집기 \(coverage.completedRequiredCount)/\(coverage.requiredCount)개가 응답했습니다."
        }
        let labels = coverage.requiredIssues.prefix(2).map(\.label).joined(separator: ", ")
        return "완료하지 못한 필수 수집기: \(labels.isEmpty ? "확인 불가" : labels)"
    }

    private func changeDetail(_ change: StorageChangeSummary) -> String {
        if let cause = change.primaryCause {
            return "\(cause.label)이 함께 \(cause.deltaGB >= 0 ? "증가" : "감소")했습니다. 인과관계는 확정하지 않습니다."
        }
        if change.causeNotCaptured {
            return "여유 공간은 변했지만 현재 추적 범위에서 함께 변한 경로를 찾지 못했습니다."
        }
        return "여유 공간과 추적 경로의 변화를 비교했습니다."
    }
}

private struct StatusNavigationRow: View {
    let symbol: String
    let title: String
    let detail: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(value)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 5)
        }
        .buttonStyle(.plain)
    }
}

private struct StatusRecoverySection: View {
    let assessment: IncidentAssessment
    let storage: StorageSnapshot?
    let isBusy: Bool
    let runScan: () -> Void
    let onOpenStorage: (StorageWorkspaceSection) -> Void
    let onOpenSecurity: () -> Void
    let onOpenActivity: () -> Void

    var body: some View {
        Section("복구 및 다음 행동") {
            StatusActionRow(
                symbol: actionSymbol,
                title: actionTitle,
                detail: actionDetail,
                value: actionValue,
                actionTitle: buttonTitle,
                action: action
            )
            .disabled(isBusy)
        }
    }

    private var actionSymbol: String {
        switch assessment.kind {
        case .securityDanger, .securityAttention: return "lock.shield"
        case .storageCritical: return "internaldrive"
        case .collectionIncomplete, .noResult: return "arrow.clockwise"
        case .browserAutomation, .runtimeAttention: return "hammer"
        case .storageDrop, .clear: return "clock.arrow.circlepath"
        }
    }

    private var actionTitle: String {
        switch assessment.kind {
        case .securityDanger, .securityAttention: return "증거를 먼저 확인하세요"
        case .storageCritical: return "승인 가능한 정리 후보를 검토하세요"
        case .collectionIncomplete, .noResult: return "검사 범위를 다시 수집하세요"
        case .browserAutomation: return "자동화 소유자와 격리 설정을 확인하세요"
        case .runtimeAttention: return "끝난 개발 작업만 정상 종료하세요"
        case .storageDrop: return "감소 시점과 함께 변한 경로를 확인하세요"
        case .clear: return "변화 기록을 유지하세요"
        }
    }

    private var actionDetail: String {
        switch assessment.kind {
        case .collectionIncomplete, .noResult:
            return "새 검사는 기존 기록을 지우지 않고 현재 수집 성공 여부를 함께 남깁니다."
        case .browserAutomation:
            return "기본 Chrome 자동화와 잔류 프로세스를 구분하며 자동 종료하지 않습니다."
        case .storageCritical:
            return "세션 기록과 개발 필수 자산은 자동 정리 대상에서 제외합니다."
        case .securityDanger, .securityAttention:
            return "경로, 실행 맥락과 수집 범위를 확인한 뒤 별도 제거 여부를 판단합니다."
        case .runtimeAttention:
            return "Codex·Claude 세션 데이터는 보존하고 실행 중인 작업만 구분합니다."
        case .storageDrop:
            return "크기가 함께 변한 사실과 실제 원인을 구분해서 보여줍니다."
        case .clear:
            return "급격한 변화가 생기면 제한된 후보 경로 스냅샷을 남길 수 있습니다."
        }
    }

    private var actionValue: String {
        switch assessment.kind {
        case .storageCritical: return storage?.reclaimableText ?? "측정 불가"
        case .browserAutomation: return "자동 종료 없음"
        case .collectionIncomplete, .noResult: return "로컬 검사"
        default: return assessment.value
        }
    }

    private var buttonTitle: String {
        switch assessment.kind {
        case .collectionIncomplete, .noResult: return "다시 검사"
        case .securityDanger, .securityAttention: return "보안 보기"
        case .storageCritical: return "후보 보기"
        case .browserAutomation, .runtimeAttention: return "개발 보기"
        case .storageDrop, .clear: return "기록 보기"
        }
    }

    private var action: () -> Void {
        switch assessment.kind {
        case .collectionIncomplete, .noResult: return runScan
        case .securityDanger, .securityAttention: return onOpenSecurity
        case .storageCritical: return { onOpenStorage(.cleanup) }
        case .browserAutomation, .runtimeAttention: return { onOpenStorage(.development) }
        case .storageDrop, .clear: return onOpenActivity
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
