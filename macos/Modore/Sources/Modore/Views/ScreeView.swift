import SwiftUI

/// TimeQuota's quota.json, read-only -- the deliberate boundary between the
/// two products (see TimeQuotaCardService). The section only exists while
/// the file is present, fresh, and parseable, so machines without TimeQuota
/// never see a trace of it.
struct TimeQuotaSection: View {
    let snapshot: TimeQuotaSnapshot

    var body: some View {
        Section {
            if !snapshot.collectionHealthy {
                ScreeNoticeRow(
                    symbol: "exclamationmark.triangle",
                    title: "TimeQuota 수집이 끊겼습니다",
                    detail: "마지막 기록이 신선하지 않아 수치를 표시하지 않습니다. TimeQuota 쪽 수집 상태를 확인하세요.",
                    tint: Color.secondary
                )
            } else {
                if let window = snapshot.window {
                    HStack(spacing: 12) {
                        Image(systemName: "gauge.with.needle")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(window.provider) 주간 사용량")
                                .font(.body.weight(.medium))
                            if let resetsAt = window.resetsAt {
                                Text("리셋 \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(Self.percentText(window.usedPercent))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
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
                        Text(Self.percentText(row.percent))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.vertical, 2)
                }
                ForEach(inactiveProviders) { provider in
                    ScreeNoticeRow(
                        symbol: "clock.badge.questionmark",
                        title: "\(provider.name): \(Self.stateText(provider.state))",
                        detail: "이 공급자의 사용량은 아직 수집되지 않고 있습니다.",
                        tint: Color.secondary
                    )
                }
            }
        } header: {
            NativeSectionHeader(
                title: "AI 사용량 (TimeQuota)",
                subtitle: "TimeQuota가 로컬에 기록한 quota.json을 읽기만 합니다. 소진 상위는 세션 메타데이터 집계이며 대화 내용은 관여하지 않습니다.",
                value: snapshot.window.map { "\($0.provider) \(Self.percentText($0.usedPercent))" } ?? ""
            )
        }
    }

    /// Providers whose collection is not currently succeeding -- the healthy
    /// ones are already represented by the numbers above.
    private var inactiveProviders: [TimeQuotaSnapshot.ProviderState] {
        snapshot.providerStates.filter { $0.state != "recent-success" }
    }

    private static func percentText(_ value: Double) -> String {
        value == value.rounded()
            ? String(format: "%.0f%%", value)
            : String(format: "%.1f%%", value)
    }

    private static func stateText(_ state: String) -> String {
        switch state {
        case "never-attempted": return "수집 시작 전"
        case "attempted-then-failed": return "수집 실패"
        case "stale-success": return "마지막 성공이 오래됨"
        default: return state
        }
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
                             : "\(session.tool) · \(session.storyAlive ? "작업 경로 현존" : "작업 경로 소멸")")
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

    var body: some View {
        Section {
            if items.isEmpty {
                Text("등록된 에이전트 워크트리가 없습니다.")
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
        } header: {
            NativeSectionHeader(
                title: "에이전트 워크트리",
                subtitle: "git 증거(dirty·미푸시 커밋)만으로 판정한 미리보기 등급입니다. 삭제 전 재검증이 필요합니다.",
                value: items.isEmpty ? "" : "보호 \(protectedCount)/\(items.count)"
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
            LabeledContent("케이스 유령", value: "\(summary.caseGhosts)")
            LabeledContent("고아 세션", value: "\(unresolvedSessions)")
        } header: {
            NativeSectionHeader(
                title: "작업 경로 계보",
                subtitle: "세션 기록이 기억하는 모든 작업 경로를 현존·소멸로 분류한 집계입니다.",
                value: "\(summary.total)곳"
            )
        }
    }
}
