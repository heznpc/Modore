import SwiftUI

struct CleanupWorkspaceList: View {
    @EnvironmentObject private var model: ScanModel
    let storage: StorageSnapshot

    var body: some View {
        List {
            StorageIncidentCauseSection(event: model.storageWatchPathEvents.last)
            StorageIncidentTimelineSection()
            StorageIncidentContextSection()
            CleanupCandidateSection(storage: storage)
            if !storage.reviewCandidates.isEmpty {
                CleanupProtectedSection(storage: storage)
            }
        }
        .listStyle(.inset)
        .accessibilityLabel("저장공간 정리 항목")
        .task { await model.refreshStorageWatchEvidence() }
        .onDisappear { model.cancelStorageEvidenceSearch() }
    }
}

private struct StorageIncidentCauseSection: View {
    let event: StorageWatchPathEvent?

    var body: some View {
        Section {
            if let event {
                ForEach(event.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        NativeStatusGlyph(
                            symbol: row.measured ? "folder" : "questionmark.folder",
                            tint: .secondary
                        )
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.label)
                                .font(.body.weight(.medium))
                            Text(row.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .help(row.path)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(measurementText(row))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(row.measured ? .primary : .secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text("부족 경고 당시의 known root 스냅샷을 아직 확인하지 못했습니다.")
                    .foregroundStyle(.secondary)
            }

            Text("원인을 모두 설명하지는 못했습니다.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
        } header: {
            NativeSectionHeader(
                title: "최근 부족 시점에 무엇이 컸나",
                subtitle: "최근 부족 경고 때 함께 측정한 known root입니다. 큰 항목이라는 사실만 확인하며 원인으로 단정하지 않습니다.",
                value: event?.capturedAt.formatted(date: .abbreviated, time: .shortened) ?? "확인 안 됨"
            )
        }
    }

    private func measurementText(_ row: StorageWatchPathSnapshot) -> String {
        guard row.measured else {
            return row.status == "timed_out" ? "시간 제한" : "측정 못함"
        }
        return String(format: "%.1fGB", row.sizeGB)
    }
}

private struct StorageIncidentTimelineSection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Section {
            HStack(spacing: 8) {
                TextField("예: DerivedData, npm cache clean", text: $model.storageEvidenceQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.runStorageEvidenceSearch() }
                Button(model.storageEvidenceRunning ? "확인 중…" : "이전 기록 확인") {
                    model.runStorageEvidenceSearch()
                }
                .buttonStyle(.bordered)
                .disabled(
                    model.storageEvidenceRunning
                    || model.storageEvidenceQuery.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }

            if model.storageEvidenceRunning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("대화와 로컬 기록을 확인하는 중…")
                        .foregroundStyle(.secondary)
                }
            } else if let error = model.storageEvidenceError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error).foregroundStyle(.secondary)
                    Button("다시 시도") { model.runStorageEvidenceSearch() }
                        .buttonStyle(.link)
                }
            } else if let result = model.storageEvidence {
                Text("“\(result.query)” · \(result.matchSummary)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let note = result.coverageNote {
                    Text(note)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(StorageEvidenceTimelineItem.queryItems(from: result)) { item in
                    StorageEvidenceTimelineRow(item: item)
                }
            } else {
                Text("위의 큰 항목이나 기억나는 정리 명령을 입력하면 과거 언급과 provider 도구 기록을 구분해 확인합니다.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            NativeSectionHeader(
                title: "이전에 비슷한 문제를 어떻게 해결했나요?",
                subtitle: "검색은 Return 또는 버튼을 눌렀을 때만 시작하며 질문은 프로세스 인자에 남기지 않습니다."
            )
        }
    }
}

private struct StorageIncidentContextSection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        if let result = model.storageEvidence {
            Section {
                ForEach(StorageEvidenceTimelineItem.contextItems(from: result)) { item in
                    StorageEvidenceTimelineRow(item: item)
                }
                Text("검색어와 직접 일치한 기록이 아닙니다. 시각 순서로 함께 놓았을 뿐이며, 같은 시간대의 앞뒤 순서가 원인을 증명하지 않습니다.")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } header: {
                NativeSectionHeader(
                    title: "주변 로컬 기록",
                    subtitle: "최근 Modore 조치 영수증과 저장공간 관찰입니다. 검색 결과와 별도로 봅니다."
                )
            }
        }
    }
}

private struct StorageEvidenceTimelineRow: View {
    let item: StorageEvidenceTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            NativeStatusGlyph(symbol: item.symbol, tint: .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.evidenceLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(item.title)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(item.displayTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct StorageEvidenceTimelineItem: Identifiable {
    let id: String
    let occurredAt: Date?
    let evidenceLabel: String
    let symbol: String
    let title: String
    let detail: String

    var displayTime: String {
        guard let occurredAt else { return "시각 확인 안 됨" }
        // Date's formatted representation uses the person's current locale
        // and timezone. In particular, a UTC storage-watch timestamp must not
        // be shown as wall-clock local time merely by stripping its trailing Z.
        return occurredAt.formatted(date: .abbreviated, time: .standard)
    }

    static func queryItems(from result: ScreeEvidenceResult) -> [Self] {
        let mentions = result.conversationMentions.map { mention in
            Self(
                id: "mention|\(mention.eventId ?? mention.source)|\(mention.index)",
                occurredAt: isoDate(mention.at ?? ""),
                evidenceLabel: ScreeEvidenceKind.conversationMention.label,
                symbol: "text.bubble",
                title: mention.snippet,
                detail: [mention.tool, location(mention.workspace), mention.isUser ? "나" : "에이전트"]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            )
        }
        let invocations = result.providerToolInvocations.enumerated().map { index, invocation in
            Self(
                id: "invocation|\(invocation.callId)|\(invocation.source)|\(index)",
                occurredAt: isoDate(invocation.at),
                evidenceLabel: providerStatusLabel(invocation.status),
                symbol: "terminal",
                title: invocation.command,
                detail: [invocation.tool, location(invocation.workspace)]
                    .filter { !$0.isEmpty }.joined(separator: " · ")
            )
        }
        return sorted(mentions + invocations)
    }

    static func contextItems(from result: ScreeEvidenceResult) -> [Self] {
        let receipts = result.modoreCleanupReceipts.enumerated().map { index, receipt in
            let estimate = receipt.estimatedKB.map(sizeText(kilobytes:))
            let reclaimed = receipt.reclaimedKB.map(sizeText(kilobytes:))
            let physicalDelta = receipt.physicalDeltaKB.map(sizeText(kilobytes:))
            return Self(
                id: "receipt|\(receipt.at)|\(receipt.recipeId)|\(index)",
                occurredAt: isoDate(receipt.at),
                evidenceLabel: ScreeEvidenceKind.modoreCleanupReceipt.label,
                symbol: receipt.status == "blocked" ? "nosign" : "checkmark.seal",
                title: receipt.label.isEmpty ? receipt.recipeId : receipt.label,
                detail: [
                    cleanupStatusText(receipt.status),
                    reclaimed.map { "회수 기록 \($0)" },
                    physicalDelta.map { "가용 공간 변화 \($0)" },
                    estimate.map { "사전 추정 \($0)" },
                ]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            )
        }
        let observations = result.filesystemObservations.enumerated().map { index, observation in
            let free = sizeText(kilobytes: observation.freeKB)
            let drop = observation.dropKB > 0
                ? "직전 표본보다 \(sizeText(kilobytes: observation.dropKB)) 감소"
                : statusText(observation.status) ?? "상태 확인 안 됨"
            return Self(
                id: "observation|\(observation.at)|\(index)",
                occurredAt: isoDate(observation.at),
                evidenceLabel: ScreeEvidenceKind.filesystemObservation.label,
                symbol: "internaldrive",
                title: "사용 가능 \(free)",
                detail: drop
            )
        }
        return sorted(receipts + observations)
    }

    private static func sorted(_ items: [Self]) -> [Self] {
        items.sorted {
            switch ($0.occurredAt, $1.occurredAt) {
            case let (left?, right?) where left != right: return left > right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return $0.id < $1.id
            }
        }
    }

    private static func isoDate(_ raw: String) -> Date? {
        guard !raw.isEmpty else { return nil }
        if let fractional = try? Date.ISO8601FormatStyle(
            includingFractionalSeconds: true
        ).parse(raw) {
            return fractional
        }
        return try? Date.ISO8601FormatStyle().parse(raw)
    }

    private static func location(_ path: String) -> String {
        path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent
    }

    private static func sizeText(kilobytes: Int64) -> String {
        ByteCountFormatter.string(
            fromByteCount: max(0, kilobytes) * 1_024,
            countStyle: .file
        )
    }

    private static func cleanupStatusText(_ status: String) -> String? {
        switch status {
        case "complete": return "실행 완료"
        case "partial": return "부분 실행"
        case "blocked": return "실행 차단"
        default: return statusText(status)
        }
    }

    private static func providerStatusLabel(_ status: String) -> String {
        switch status {
        case "completed": return "실행 완료 기록"
        case "failed": return "실행 실패 기록"
        case "denied": return "실행 차단 기록"
        case "requested": return "도구 호출 요청됨"
        default: return "실행 여부 확인 안 됨"
        }
    }

    private static func statusText(_ status: String) -> String? {
        switch status {
        case "warning": return "부족 상태"
        case "normal": return "정상 범위"
        case "failed": return "실패 기록"
        case "": return nil
        default: return status
        }
    }
}

private struct CleanupCandidateSection: View {
    let storage: StorageSnapshot

    var body: some View {
        Section {
            ForEach(executableCandidates) { item in
                CleanupCandidateRow(item: item)
            }
        } header: {
            NativeSectionHeader(
                title: "정리 미리보기 가능",
                subtitle: "합계는 실행 가능한 대상의 점유 추정이며, 실행 직전에 다시 측정합니다.",
                value: storage.reclaimableText
            )
        }

        if !manualCandidates.isEmpty {
            Section {
                ForEach(manualCandidates) { item in
                    CleanupCandidateRow(item: item)
                }
            } header: {
                NativeSectionHeader(
                    title: "수동 확인",
                    subtitle: "실행 recipe가 없는 넓은 경로입니다. Finder에서 개별 항목을 검토하세요.",
                    value: "\(manualCandidates.count)개"
                )
            }
        }
    }

    private var executableCandidates: [StorageItem] {
        storage.cleanupCandidates.filter(\.hasSupportedCleanupRecipe)
    }

    private var manualCandidates: [StorageItem] {
        storage.cleanupCandidates.filter { !$0.hasSupportedCleanupRecipe }
    }
}

struct CleanupCandidateRow: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        WorkspaceStorageItemRow(
            item: item,
            fallbackSymbol: cleanupSymbol,
            status: item.canCleanup || canRetryMeasurement ? nil : "수동 확인",
            actionTitle: actionTitle
        ) {
            if item.measureStatus == "timed_out" {
                model.runScan()
            } else {
                model.prepareCleanup(item)
            }
        }
        .contextMenu { StorageItemContextMenu(item: item) }
    }

    private var actionTitle: String? {
        if canRetryMeasurement { return "다시 측정" }
        return item.canCleanup ? "정리 검토…" : nil
    }

    private var canRetryMeasurement: Bool {
        item.measureStatus == "timed_out" && item.hasSupportedCleanupRecipe
    }

    private var cleanupSymbol: String {
        if item.measureStatus == "timed_out" { return "hourglass" }
        if item.label.localizedCaseInsensitiveContains("Playwright") {
            return "rectangle.stack.badge.play"
        }
        if item.label.localizedCaseInsensitiveContains("cache") {
            return "folder.badge.gearshape"
        }
        return "arrow.triangle.2.circlepath"
    }
}

private struct CleanupProtectedSection: View {
    @State private var showsSmallItems = false
    let storage: StorageSnapshot

    var body: some View {
        let groups = ProtectedStoragePresentation.split(storage.reviewCandidates)

        Section {
            ForEach(groups.prominent) { item in
                WorkspaceStorageItemRow(
                    item: item,
                    fallbackSymbol: "lock.shield",
                    status: "보호됨"
                )
                .contextMenu { StorageItemContextMenu(item: item) }
            }
            if !groups.small.isEmpty {
                DisclosureGroup(isExpanded: $showsSmallItems) {
                    ForEach(groups.small) { item in
                        WorkspaceStorageItemRow(
                            item: item,
                            fallbackSymbol: "lock.shield",
                            status: "보호됨"
                        )
                        .contextMenu { StorageItemContextMenu(item: item) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "ellipsis.circle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 32)
                        Text("작은 보호 항목")
                            .font(.body.weight(.medium))
                        Spacer()
                        Text("\(groups.small.count)개")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 6)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("작은 보호 항목 \(groups.small.count)개")
                }
            }
        } header: {
            NativeSectionHeader(
                title: "보호 및 확인",
                subtitle: "Codex·Claude 세션, 작업 기록과 내부 DB는 자동 정리하지 않습니다.",
                value: storage.reviewText
            )
        }
    }
}

enum ProtectedStoragePresentation {
    static let prominentThresholdGB = 0.01

    static func split(_ items: [StorageItem]) -> (
        prominent: [StorageItem],
        small: [StorageItem]
    ) {
        let prominent = items.filter {
            $0.measureStatus == "timed_out" || $0.sizeGB >= prominentThresholdGB
        }
        let small = items.filter {
            $0.measureStatus != "timed_out" && $0.sizeGB < prominentThresholdGB
        }
        return (prominent, small)
    }
}

struct StorageItemContextMenu: View {
    @EnvironmentObject private var model: ScanModel
    let item: StorageItem

    var body: some View {
        Button { model.revealStorageItem(item) } label: {
            Label("Finder에서 보기", systemImage: "folder")
        }
        Button { model.copyGuide(for: item) } label: {
            Label("정보 복사", systemImage: "doc.on.clipboard")
        }
    }
}
