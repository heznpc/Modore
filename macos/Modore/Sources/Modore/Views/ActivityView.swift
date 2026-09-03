import SwiftUI

struct ActivityPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            StorageWatchActivitySection()
            ContinuousObservationSection()

            if let evidence = model.latestStorageWatchEvidence {
                StorageWatchEvidenceSection(evidence: evidence)
            }

            if !model.storageHistory.isEmpty {
                ScanHistorySection(entries: model.storageHistory)
            }

            ScanLogSection(store: model.logStore, clearAction: model.clearLog)
        }
        .macSettingsFormStyle()
        .task {
            await model.refreshStorageWatchEvidence()
        }
        .onDisappear {
            model.cancelActivityScreenTasks()
        }
    }
}

private struct StorageWatchActivitySection: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: watchSymbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.storageWatchEnabled ? "저장공간 감시 켜짐" : "저장공간 감시 꺼짐")
                        .font(.body.weight(.medium))
                    Text(model.storageWatchDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StorageWatchSettingsButton()
            }
            if !model.freeSpaceSamples.isEmpty {
                FreeSpaceTrendView(samples: Array(model.freeSpaceSamples.suffix(48)))
                    .frame(height: 120)
            } else {
                Text("시간별 표본이 아직 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            NativeSectionHeader(
                title: "저장공간 변화",
                subtitle: "평소에는 여유 공간만 기록하고, 부족 진입·급감 시 제한된 경로와 실제로 확보된 시스템 신호를 남깁니다.",
                value: "\(model.freeSpaceSamples.count)개 표본"
            )
        }
    }

    /// "켜짐" 표시는 설치가 정상이라는 뜻일 뿐, 실제로 최근에 실행됐다는 뜻이
    /// 아니었다 -- 멈춰버린 감시와 꺼진 감시가 같은 체크마크로 보였다.
    /// 색은 바꾸지 않는다(보안 위험 색상은 진짜 위험에만 예약); 모양만 구분한다.
    private var watchSymbol: String {
        guard model.storageWatchEnabled else { return "pause.circle" }
        switch model.storageWatchHealthState {
        case .neverAttempted: return "clock.badge.questionmark"
        case .attemptedThenFailed: return "exclamationmark.circle"
        case .recentSuccess: return "checkmark.circle"
        case .staleSuccess: return "clock.badge.exclamationmark"
        }
    }
}

private struct ContinuousObservationSection: View {
    @EnvironmentObject private var model: ScanModel
    @State private var windowSeconds = 60
    /// The window the in-flight run was actually started with, so the
    /// progress caption cannot drift from it.
    @State private var runningWindowSeconds = 60

    var body: some View {
        Section {
            HStack {
                Picker("관찰 시간", selection: $windowSeconds) {
                    Text("30초").tag(30)
                    Text("1분").tag(60)
                    Text("2분").tag(120)
                    Text("5분").tag(300)
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                // Left enabled mid-run, the picker rewrote the caption below
                // to a window the run in progress is not actually using.
                .disabled(model.observationInFlight)
                Spacer()
                Button(model.observationInFlight ? "관찰 중…" : "지금 관찰하기") {
                    runningWindowSeconds = windowSeconds
                    model.observeNow(windowSeconds: windowSeconds)
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || model.observationInFlight)
            }

            if model.observationInFlight {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("\(runningWindowSeconds)초 동안 CPU와 네트워크를 관찰하는 중입니다…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if let message = model.observationErrorMessage {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let result = model.observationResult {
                ObservationResultRows(result: result)
            } else {
                Text("기본 검사는 순간 스냅샷만 봅니다. 관찰을 시작하면 지정한 시간 동안 실제 CPU 사용과 새로 나타난 네트워크 연결만 골라 보여줍니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            NativeSectionHeader(
                title: "CPU·네트워크 관찰",
                subtitle: "지정한 시간 동안 두 시점을 비교해 실제 점유와 새 연결만 보고합니다. 예약 실행이 아니라 누를 때만 동작합니다.",
                value: model.observationResult.map { "\($0.windowSeconds)초 관찰됨" } ?? "미실행"
            )
        }
    }
}

private struct ObservationResultRows: View {
    let result: ObservationResult

    var body: some View {
        if result.processRows.isEmpty {
            Text("관찰 구간 동안 뚜렷한 CPU 사용이 없었습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(result.processRows) { row in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.name)
                            .font(.body.weight(.medium))
                        Text(row.isDetachedFromAnApp ? "\(row.ownerName)에서 시작된 셸 작업" : row.ownerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(String(format: "%.1f%%", row.percent))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
            }
        }

        if result.networkUnavailable {
            Text("lsof를 사용할 수 없어 네트워크는 관찰하지 못했습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if result.newConnectionRows.isEmpty {
            Text("관찰 구간 동안 새로 나타난 연결이나 포트가 없었습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            ForEach(result.newConnectionRows) { row in
                HStack {
                    Image(systemName: row.isListening ? "antenna.radiowaves.left.and.right" : "network")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.process)
                            .font(.body.weight(.medium))
                        Text(row.isListening ? "새 수신 포트" : "새 연결")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(row.address)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct StorageWatchEvidenceSection: View {
    let evidence: StorageWatchEvidenceEvent

    var body: some View {
        Section {
            if let signalEvent = evidence.signalEvent {
                ForEach(signalEvent.rows) { signal in
                    StorageWatchSignalRow(signal: signal)
                }
            }
            if let event = evidence.pathEvent {
                ForEach(event.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        NativeStatusGlyph(
                            symbol: row.measured ? "folder" : "clock",
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
                        Text(row.measurementText)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(row.measured ? .primary : .secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            NativeSectionHeader(
                title: "최근 부족 시점의 증거",
                subtitle: evidenceSummary,
                value: evidence.capturedAt.formatted(date: .abbreviated, time: .shortened)
            )
        }
    }

    private var evidenceSummary: String {
        let swap = evidence.signalEvent?.collectionSummary(for: .swap, label: "스왑")
            ?? "스왑 신호 없음"
        let rss = evidence.signalEvent?.collectionSummary(for: .processRSS, label: "상위 RAM")
            ?? "상위 RAM 신호 없음"
        return "같은 점검: \(swap) · \(rss) · \(pathCollectionSummary). 큰 값만으로 원인을 확정하지 않습니다."
    }

    private var pathCollectionSummary: String {
        guard let rows = evidence.pathEvent?.rows, !rows.isEmpty else {
            return "경로 신호 없음"
        }
        if rows.allSatisfy(\.measured) { return "제한된 경로 측정 완료" }
        if rows.contains(where: \.measured) { return "제한된 경로 일부만 측정" }
        return "제한된 경로 측정 미완료"
    }

}

private struct ScanHistorySection: View {
    let entries: [StorageHistoryEntry]

    var body: some View {
        Section {
            ForEach(Array(entries.suffix(12).reversed())) { entry in
                RecentScanHistoryRow(
                    entry: entry,
                    previous: entries.last(where: { $0.capturedAt < entry.capturedAt })
                )
            }
        } header: {
            NativeSectionHeader(
                title: "사고 및 검사 이력",
                subtitle: "검사 당시의 주요 판단, 수집 완전성과 저장공간 변화를 함께 남깁니다.",
                value: "\(entries.count)회"
            )
        }
    }
}

private struct StorageWatchSettingsButton: View {
    var body: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                Label("감시 설정…", systemImage: "gear")
            }
            .buttonStyle(.bordered)
        } else {
            Text("⌘, 에서 설정")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ScanLogSection: View {
    @ObservedObject var store: ScanLogStore
    let clearAction: () -> Void

    var body: some View {
        Section {
            ScrollView {
                Text(store.isEmpty ? "아직 실행 로그가 없습니다." : store.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(store.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 200, maxHeight: 320)
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
        } header: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("실행 로그")
                    Text("검사와 승인형 정리의 로컬 출력입니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(nil)
                }
                Spacer()
                Button("로그 지우기", systemImage: "trash", action: clearAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(store.isEmpty)
                    .textCase(nil)
            }
        }
    }
}

struct RecentScanHistoryRow: View {
    let entry: StorageHistoryEntry
    let previous: StorageHistoryEntry?
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            // Honor the system "Reduce Motion" setting: expand instantly instead
            // of animating when the user has asked for reduced motion.
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    NativeStatusGlyph(symbol: historySymbol, tint: historyTint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.incidentTitle ?? entry.capturedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(isExpanded ? nil : 1)
                        Text(historyDetail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 1)
                            .fixedSize(horizontal: false, vertical: isExpanded)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(entry.incidentValue ?? String(format: "%.1fGB", entry.freeGB))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                        Text(entry.incidentValue == nil ? "사용 가능" : "당시 판단")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                if isExpanded {
                    expandedFacts
                        .padding(.leading, 36)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .help(isExpanded ? "접으려면 클릭" : historyDetail)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(isExpanded ? "당시 요약을 접습니다." : "당시 증거 요약을 펼칩니다.")
    }

    private var expandedFacts: some View {
        VStack(alignment: .leading, spacing: 3) {
            historyFactRow(
                "검사 시각",
                entry.capturedAt.formatted(date: .long, time: .standard)
            )
            historyFactRow(
                "저장공간",
                String(
                    format: "사용 가능 %.1fGB · 사용 중 %.1fGB · 전체 %.1fGB",
                    entry.freeGB,
                    entry.usedGB,
                    entry.totalGB
                )
            )
            if let complete = entry.collectionComplete {
                historyFactRow(
                    "수집 완전성",
                    complete
                        ? "필수 수집기가 모두 응답한 검사였습니다."
                        : "필수 수집기 일부가 완료되지 않아 당시 판단이 보류 기준이었습니다."
                )
            }
            if let verdict = entry.browserVerdict {
                historyFactRow("브라우저 자동화", browserVerdictText(verdict))
            }
            if let evidence = entry.evidence {
                historyFactRow(
                    "수집된 증거",
                    "프로세스 \(evidence.processCount)개 · 외부 연결 \(evidence.networkConnectionCount)개 · 수신 포트 \(evidence.listeningPortCount)개 · 확인 항목 \(evidence.attentionFindingCount)건"
                )
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func historyFactRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .fontWeight(.medium)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func browserVerdictText(_ verdict: String) -> String {
        // Verdict tokens are emitted by scanner_helper.jxa.js as orphaned /
        // conflict_possible / isolated_active / clear; matching the wrong token
        // ("conflict") let real verdicts fall through to the raw protocol string.
        switch verdict {
        case "orphaned": return "소유 작업을 찾지 못한 자동화가 있었습니다."
        case "conflict_possible": return "기본 Chrome과 자동화 충돌 가능성이 있었습니다."
        case "isolated_active": return "격리된 자동화 브라우저가 실행 중이었습니다."
        case "clear": return "자동화 충돌 신호가 없었습니다."
        default: return verdict
        }
    }

    private var accessibilitySummary: String {
        let title = entry.incidentTitle
            ?? entry.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(title). \(historyDetail)"
    }

    private var change: StorageChangeSummary? {
        guard let previous else { return nil }
        return StorageChangeSummary(entries: [previous, entry])
    }

    private var changeDescription: String {
        guard let change else { return "첫 비교 기준점" }
        guard abs(change.freeDeltaGB) >= 0.05 else {
            if let largest = change.largestChanges.first {
                return "사용 가능 거의 같음 · \(historyEvidence(largest))"
            }
            return "추적 경로와 여유 공간 변화 없음"
        }

        var parts = [String(format: "사용 가능 %+.1fGB", change.freeDeltaGB)]
        if let primary = change.primaryCause {
            let label = change.consumedGB >= 0.05 ? "감소 후보" : "회복 후보"
            parts.append("\(label) \(historyEvidence(primary))")
        } else {
            parts.append(change.consumedGB >= 0.05 ? "감소 원인 미포착" : "회복 원인 미포착")
        }

        if let opposite = change.oppositeDirectionChanges.first {
            let label = change.consumedGB >= 0.05 ? "동시 감소" : "동시 증가"
            parts.append("\(label) \(historyEvidence(opposite))")
        }

        if !change.causeNotCaptured, change.unattributedConsumedGB >= 0.1 {
            parts.append(String(format: "추적 밖 사용 %.1fGB", change.unattributedConsumedGB))
        } else if !change.causeNotCaptured, change.unattributedRecoveredGB >= 0.1 {
            parts.append(String(format: "추적 밖 회복 %.1fGB", change.unattributedRecoveredGB))
        }
        if change.causeNotCaptured {
            parts.append("현재 수집 범위 밖")
        }
        if parts.count > 1 {
            return parts.joined(separator: " · ")
        }
        return "추적 경로 변화 없음"
    }

    private var historyDetail: String {
        guard entry.incidentTitle != nil else { return changeDescription }
        let timestamp = entry.capturedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(timestamp) · \(changeDescription) · 사용 가능 \(String(format: "%.1fGB", entry.freeGB))"
    }

    private func historyEvidence(_ item: StorageItemChange) -> String {
        if item.appearedInTrackedList {
            return String(
                format: "%@ 현재 %.1fGB(목록에 새로 나타남)",
                item.label,
                item.afterGB
            )
        }
        if item.disappearedFromTrackedList {
            return String(
                format: "%@ 직전 %.1fGB(현재 목록에서 사라짐)",
                item.label,
                item.beforeGB
            )
        }
        return String(format: "%@ %+.1fGB", item.label, item.deltaGB)
    }

    private var historySymbol: String {
        switch entry.incidentKind {
        case "security_danger": return "exclamationmark.shield"
        case "storage_critical": return "internaldrive.fill"
        case "collection_incomplete": return "questionmark.shield"
        case "browser_automation": return "rectangle.on.rectangle"
        case "storage_drop": return "arrow.down.right.circle"
        case "security_attention": return "info.circle"
        case "runtime_attention": return "hammer"
        case "clear": return "checkmark.circle"
        default: break
        }
        guard let change else { return "record.circle" }
        if change.freeDeltaGB < -0.05 { return "arrow.down.right" }
        if change.freeDeltaGB > 0.05 { return "arrow.up.right" }
        return "equal.circle"
    }

    private var historyTint: Color {
        switch entry.incidentKind {
        case "security_danger", "storage_critical": return .red
        default: return .secondary
        }
    }

}

struct FreeSpaceTrendView: View {
    let samples: [FreeSpaceSample]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let first = samples.first, let last = samples.last {
                    Text("\(first.freeGB, specifier: "%.1f")GB")
                    Image(systemName: "arrow.right")
                    Text("\(last.freeGB, specifier: "%.1f")GB")
                        .fontWeight(.semibold)
                }
                Spacer()
                Text("최근 \(samples.count)회")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            FreeSpaceSparkline(values: samples.map(\.freeGB))
        }
    }
}

struct FreeSpaceSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            makePath(in: proxy.size)
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("여유 공간 추세 그래프")
        .accessibilityValue(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        guard let first = values.first, let last = values.last else {
            return "표본 없음"
        }
        let minimum = values.min() ?? last
        let maximum = values.max() ?? last
        return String(
            format: "최근 %d회, 처음 %.1fGB, 현재 %.1fGB, 최저 %.1fGB, 최고 %.1fGB",
            values.count,
            first,
            last,
            minimum,
            maximum
        )
    }

    private func makePath(in size: CGSize) -> Path {
        let points = chartPoints(in: size)
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func chartPoints(in size: CGSize) -> [CGPoint] {
        let minimum = values.min() ?? 0
        let maximum = values.max() ?? 1
        let span = max(maximum - minimum, 0.5)
        let horizontalStep = values.count <= 1
            ? 0
            : size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let x = horizontalStep * CGFloat(index)
            let normalizedValue = CGFloat((value - minimum) / span)
            return CGPoint(x: x, y: size.height * (1 - normalizedValue))
        }
    }
}
