import SwiftUI

/// QuotaPie's quota.json, read-only -- the deliberate boundary between the
/// collector and Modore (see TimeQuotaCardService). A missing file remains
/// invisible, while an existing stale or invalid boundary remains visible as
/// a local health finding instead of silently taking the whole card away.
struct TimeQuotaSection: View {
    let state: TimeQuotaCardState

    var body: some View {
        Section {
            if case .invalid = state {
                ScreeNoticeRow(
                    symbol: "exclamationmark.triangle",
                    title: "QuotaPie 기록을 읽을 수 없습니다",
                    detail: "quota.json이 v2 계약과 맞지 않거나 안전하게 읽을 수 없습니다. 사용량 수치는 표시하지 않습니다.",
                    tint: Color.secondary
                )
            }

            if let snapshot = state.snapshot {
                if isStale {
                    ScreeNoticeRow(
                        symbol: "clock.badge.questionmark",
                        title: "QuotaPie 기록이 오래됐습니다",
                        detail: "\(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened)) 이후 새 기록이 없습니다. 수집기가 멈췄을 수 있어 사용량 수치는 숨겼습니다.",
                        tint: Color.secondary
                    )
                } else {
                    if let notice = TimeQuotaCardPresentation.headlineNotice(for: snapshot) {
                        ScreeNoticeRow(
                            symbol: notice.symbol,
                            title: notice.title,
                            detail: notice.detail,
                            tint: Color.secondary
                        )
                    } else if !snapshot.collectionHealthy {
                        ScreeNoticeRow(
                            symbol: "exclamationmark.triangle",
                            title: "QuotaPie 공급자 수집이 실패했습니다",
                            detail: "경계 파일은 갱신됐지만 표시할 공급자의 최근 수집이 성공하지 않았습니다. 마지막 수치는 숨겼습니다.",
                            tint: Color.secondary
                        )
                    }

                    if showsNumbers, let window = snapshot.window {
                        HStack(spacing: 12) {
                            Image(systemName: "gauge.with.needle")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Self.windowTitle(window: window, headline: snapshot.headline))
                                    .font(.body.weight(.medium))
                                if let resetsAt = window.resetsAt {
                                    Text("리셋 \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(window.usedPercent.map(TimeQuotaCardPresentation.percentText) ?? "확인 중")
                                .font(.callout.weight(.semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }

                if showsNumbers {
                    ForEach(snapshot.topBurn.prefix(3)) { row in
                        HStack(spacing: 12) {
                            Image(systemName: "flame")
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.remote)
                                    .font(.body.weight(.medium))
                                    .lineLimit(1)
                                if let lastActiveAt = row.lastActiveAt {
                                    Text("마지막 활동 \(lastActiveAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(TimeQuotaCardPresentation.percentText(row.percent))
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .padding(.vertical, 2)
                    }
                }

                ForEach(snapshot.providerStates) { provider in
                    let status = TimeQuotaCardPresentation.providerStatus(
                        provider,
                        boundaryIsStale: isStale
                    )
                    ScreeNoticeRow(
                        symbol: status.symbol,
                        title: status.title,
                        detail: status.detail,
                        tint: Color.secondary
                    )
                }
            }
        } header: {
            NativeSectionHeader(
                title: "AI 사용량 (QuotaPie)",
                subtitle: "QuotaPie가 로컬에 기록한 quota.json을 읽기만 합니다. 자격증명과 네트워크 수집은 QuotaPie에 남습니다.",
                value: TimeQuotaCardPresentation.headerValue(for: state)
            )
        }
    }

    private var isStale: Bool {
        if case .stale = state { return true }
        return false
    }

    private var showsNumbers: Bool {
        guard case .current(let snapshot) = state,
              snapshot.collectionHealthy else { return false }
        switch snapshot.headline?.kind {
        case .setup, .degraded: return false
        case .normal, .paceRisk, nil: return true
        }
    }

    private static func windowTitle(
        window: TimeQuotaSnapshot.Window,
        headline: TimeQuotaSnapshot.Headline?
    ) -> String {
        let kind: String
        switch headline?.windowKind {
        case .fiveHour: kind = "5시간"
        case .weekly: kind = "주간"
        case .monthly: kind = "월간"
        case .other: kind = ""
        case nil: kind = ""
        }
        return kind.isEmpty
            ? "\(TimeQuotaCardPresentation.providerName(window.provider)) 사용량"
            : "\(TimeQuotaCardPresentation.providerName(window.provider)) \(kind) 사용량"
    }
}

struct ScreeNoticeRow: View {
    let symbol: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ScreeStoresSection: View {
    let stores: [ScreeStoreStatus]

    /// Coverage, demoted from headline to footer. What the verdicts above
    /// rest on -- which stores were read and how much was in them -- in
    /// one line, with the per-store table behind a disclosure for the
    /// reader who wants it.
    var body: some View {
        Section {
            if stores.isEmpty {
                Text("인식된 세션 저장소가 없습니다.")
                    .foregroundStyle(.secondary)
            } else {
                DisclosureGroup {
                    ForEach(stores) { store in
                        HStack {
                            Image(systemName: store.status == "ok" ? "checkmark.circle" : "questionmark.circle")
                                .foregroundStyle(Color.secondary)
                            Text(store.store)
                            Spacer()
                            Text("\(store.count)개 세션")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .monospacedDigit()
                        }
                    }
                } label: {
                    Text(Self.summaryLine(stores))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            NativeSectionHeader(
                title: "검사 범위",
                subtitle: "위 판정이 근거한 저장소들입니다.",
                value: ""
            )
        }
    }

    static func summaryLine(_ stores: [ScreeStoreStatus]) -> String {
        let read = stores.filter { $0.status == "ok" }
        let total = read.reduce(0) { $0 + $1.count }
        let names = read.map(\.store).joined(separator: " · ")
        return "\(names) — \(read.count)개 저장소 · \(total)개 기록 확인"
    }
}

struct ScreeExpiringSection: View {
    let expiring: [ScreeExpiringSession]
    let preserveInFlightSource: String?
    let onPreserve: (ScreeExpiringSession) -> Void

    var body: some View {
        Section {
            if expiring.isEmpty {
                Text("곧 만료되는 세션이 없습니다.")
                    .foregroundStyle(.secondary)
            }
            ForEach(expiring.prefix(20)) { session in
                HStack(alignment: .top, spacing: 12) {
                    Text(session.daysLeft <= 0 ? "D-day" : "D-\(session.daysLeft)")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.workspaceLastComponent)
                            .font(.body.weight(.medium))
                        Text(session.ownerDeleted
                             ? "\(session.tool) · 앱에서 삭제됨 · 트랜스크립트 잔존"
                             : "\(session.tool) · \(session.workspaceStateText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if preserveInFlightSource == session.source {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button {
                            onPreserve(session)
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(preserveInFlightSource != nil)
                        .help("대화 텍스트만 마스킹하여 Markdown으로 내보내기 — 원본 백업은 작업의 대화 상세에서")
                        .accessibilityLabel("대화 내보내기")
                    }
                }
            }
        } header: {
            NativeSectionHeader(
                title: "곧 만료되는 세션",
                subtitle: "파일 나이로 추정한 보존 기한입니다. 아이콘은 대화 텍스트 내보내기이며, 도구 기록을 포함한 원본 백업은 대화 상세에서 실행합니다.",
                value: expiring.isEmpty ? "" : "\(expiring.count)건"
            )
        }
    }
}

struct ScreeWorktreeSection: View {
    let items: [ScreeWorktreeItem]
    let protectedCount: Int
    let registeredMissing: [ScreeRegisteredMissing]
    let discovery: ScreeWorktreeDiscovery

    var body: some View {
        Section {
            if items.isEmpty && registeredMissing.isEmpty {
                Text(discovery.emptyStateText)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.verdictSymbolName)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayLabel)
                            .font(.body.weight(.medium))
                        Text("\(item.branch) · \(item.reasonText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(item.verdictLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                }
            }
            ForEach(registeredMissing) { missing in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(missing.displayLabel)
                            .font(.body.weight(.medium))
                        Text("git 등록 기록은 남았지만 작업 경로가 사라졌습니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("경로 소멸")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            let missingText = registeredMissing.isEmpty
                ? ""
                : " · 경로 소멸 \(registeredMissing.count)"
            NativeSectionHeader(
                title: "에이전트 워크트리",
                subtitle: "git 증거(dirty·미푸시 커밋)만으로 판정한 미리보기 등급입니다. \(discovery.coverageText)",
                value: items.isEmpty && registeredMissing.isEmpty
                    ? ""
                    : "보호 \(protectedCount)/\(items.count)\(missingText)"
            )
        }
    }
}

struct ScreeLineageSection: View {
    let summary: ScreeLineageSummary
    let unresolvedSessions: Int

    var body: some View {
        Section {
            LabeledContent("현존 + git", value: "\(summary.aliveGit)")
            LabeledContent("현존 + 비git", value: "\(summary.alivePlain)")
            LabeledContent("소멸", value: "\(summary.vanished)")
            LabeledContent("확인 못함", value: "\(summary.unknown)")
            LabeledContent("케이스 유령", value: "\(summary.caseGhosts)")
            LabeledContent("고아 세션", value: "\(unresolvedSessions)")
        } header: {
            NativeSectionHeader(
                title: "작업 경로 계보",
                subtitle: "세션 기록이 기억하는 모든 작업 경로를 현존·소멸·확인 못함으로 분류한 집계입니다.",
                value: "\(summary.total)곳"
            )
        }
    }
}
