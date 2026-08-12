import SwiftUI

/// Displays scree's judgment — read-only. This page never deletes anything;
/// it is the "what did my AI agents leave behind" evidence scree.py already
/// computes, brought into the app instead of requiring Terminal.
struct ScreePage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            Section {
                if model.screeLoading {
                    HStack {
                        ProgressView()
                            .controlSize(.small)
                        Text("scree 실행 중…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error = model.screeError {
                    ScreeNoticeRow(
                        symbol: "exclamationmark.triangle",
                        title: "scree를 실행하지 못했습니다",
                        detail: error,
                        tint: Color.secondary
                    )
                } else if model.screeReport == nil {
                    ScreeNoticeRow(
                        symbol: "clock.badge.questionmark",
                        title: "아직 실행하지 않았습니다",
                        detail: "Claude Code·Codex·Gemini 세션과 워크트리를 메타데이터만으로 판정합니다. 대화 내용은 읽지도 저장하지도 않습니다.",
                        tint: Color.secondary
                    )
                }
                Button(model.screeReport == nil ? "지금 실행" : "다시 실행") {
                    model.refreshScreeReport()
                }
                .disabled(model.screeLoading)
            } header: {
                NativeSectionHeader(
                    title: "AI 세션 감사",
                    subtitle: "Claude Code·Codex·Gemini·VS Code 계열 세션을 메타데이터로만 조인·판정합니다. LLM 없음, 삭제 없음.",
                    value: model.screeReport != nil ? "완료" : ""
                )
            }

            if let report = model.screeReport {
                ScreeStoresSection(stores: report.stores)
                ScreeExpiringSection(expiring: report.expiring)
                ScreeWorktreeSection(items: report.worktreeItems, protectedCount: report.protectedWorktreeCount)
                ScreeLineageSection(summary: report.lineageSummary, unresolvedSessions: report.unresolvedSessions)
            }
        }
        .macSettingsFormStyle()
    }
}

private struct ScreeNoticeRow: View {
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

private struct ScreeStoresSection: View {
    let stores: [ScreeStoreStatus]

    var body: some View {
        Section("도구별 세션 저장소") {
            if stores.isEmpty {
                Text("인식된 세션 저장소가 없습니다.")
                    .foregroundStyle(.secondary)
            }
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
        }
    }
}

private struct ScreeExpiringSection: View {
    let expiring: [ScreeExpiringSession]

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
                        Text("\(session.tool) · \(session.storyAlive ? "작업 경로 현존" : "작업 경로 소멸")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
        } header: {
            NativeSectionHeader(
                title: "곧 만료되는 세션",
                subtitle: "롤링 보존 기한을 파일 나이로 추정한 예보입니다. 실제 삭제 시점은 각 도구가 결정합니다.",
                value: expiring.isEmpty ? "" : "\(expiring.count)건"
            )
        }
    }
}

private struct ScreeWorktreeSection: View {
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

private struct ScreeLineageSection: View {
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
