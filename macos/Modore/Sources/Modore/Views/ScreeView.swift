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

            if let quota = model.timeQuotaSnapshot {
                TimeQuotaSection(snapshot: quota)
            }

            if let report = model.screeReport {
                // Verdict before inventory. The page opens with what the
                // owner must not lose and what is about to vanish; how
                // many sessions each store holds is coverage, not a
                // finding, and "Codex 2,886개" answers no question anyone
                // brought to this screen.
                ScreeWorktreeSection(items: report.worktreeItems, protectedCount: report.protectedWorktreeCount)
                ScreeExpiringSection(
                    expiring: report.expiring,
                    preserveInFlightSource: model.screePreserveInFlightSource,
                    onPreserve: { model.preserveScreeSession($0) }
                )
                ScreeSessionBrowserSection(
                    index: model.sessionIndex,
                    loading: model.sessionIndexLoading,
                    error: model.sessionIndexError,
                    search: $model.sessionSearch,
                    conversationStates: model.conversationLoads,
                    conversationKey: { ScanModel.conversationKey(
                        provider: $0.provider, sessionID: $0.source, source: $0.sourceURL
                    ) },
                    onLoad: { model.refreshSessionIndex() },
                    onInspect: { model.loadConversation(for: $0) },
                    onRetryInspect: { model.loadConversation(for: $0, retry: true) }
                )
                ScreeLineageSection(summary: report.lineageSummary, unresolvedSessions: report.unresolvedSessions)
                ScreeStoresSection(stores: report.stores)
            }
        }
        .macSettingsFormStyle()
        .task {
            model.refreshTimeQuotaCard()
        }
    }
}

/// TimeQuota's quota.json, read-only -- the deliberate boundary between the
/// two products (see TimeQuotaCardService). The section only exists while
/// the file is present, fresh, and parseable, so machines without TimeQuota
/// never see a trace of it.
private struct TimeQuotaSection: View {
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

private struct ScreeExpiringSection: View {
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
                        Text("\(session.tool) · \(session.storyAlive ? "작업 경로 현존" : "작업 경로 소멸")")
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
                        .help("이 세션을 마스킹된 Markdown으로 보존")
                        .accessibilityLabel("세션 보존")
                    }
                }
            }
        } header: {
            NativeSectionHeader(
                title: "곧 만료되는 세션",
                subtitle: "롤링 보존 기한을 파일 나이로 추정한 예보입니다. 실제 삭제 시점은 각 도구가 결정합니다. 아이콘을 눌러 마스킹된 Markdown으로 미리 보존할 수 있습니다.",
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


/// The screen's actual session browser: find one conversation, open it,
/// read it.
///
/// This page opens with verdicts -- what is expiring, which worktrees are
/// unsafe -- and those answer "what should I act on". They do not answer
/// "where is the conversation I had last Tuesday", which is the question
/// that brought most people here, and until now the only way to ask it
/// was to scroll a grouped summary that named no sessions at all.
///
/// Reading a body is still one explicit act per session: the index is
/// metadata, and nothing here is an input to any verdict.
struct ScreeSessionBrowserSection: View {
    let index: SessionIndex?
    let loading: Bool
    let error: String?
    @Binding var search: String
    let conversationStates: [String: ConversationLoadState]
    let conversationKey: (SessionIndexEntry) -> String
    let onLoad: () -> Void
    let onInspect: (SessionIndexEntry) -> Void
    let onRetryInspect: (SessionIndexEntry) -> Void

    @State private var open: Set<String> = []

    /// Enough to browse; past this the list is a scroll, not a search.
    static let displayLimit = 50

    /// Case-insensitive match over label, workspace, tool and path.
    ///
    /// `nonisolated static` for the same reason the formatters in
    /// `MothballCandidateSection` are: it is a pure function over value
    /// types, and inheriting the view's main-actor isolation would make
    /// it untestable from anywhere else.
    nonisolated static func filter(
        _ sessions: [SessionIndexEntry], search: String
    ) -> [SessionIndexEntry] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return sessions }
        // Every term must match, so adding a word narrows rather than
        // widens -- typing "claude modore" should not return everything
        // Claude ever touched.
        let terms = needle.split(separator: " ").map(String.init)
        return sessions.filter { entry in
            let haystack = entry.searchHaystack
            return terms.allSatisfy { haystack.contains($0) }
        }
    }

    /// What the footer has to admit, given a cap at both ends: scree's own
    /// `--limit` and this view's.
    nonisolated static func truncationText(
        matched: Int, shown: Int, indexed: Int, total: Int
    ) -> String? {
        var notes: [String] = []
        if matched > shown {
            notes.append("일치 \(matched)개 중 \(shown)개만 표시했습니다. 검색어를 좁히세요.")
        }
        if total > indexed {
            notes.append("이 기기의 세션 \(total)개 중 최근 \(indexed)개만 목록에 있습니다.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }

    var body: some View {
        Section {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("다시 시도") { onLoad() }
                    .buttonStyle(.link)
            } else if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("세션 목록을 읽는 중…")
                        .foregroundStyle(.secondary)
                }
            } else if index == nil {
                Text("이 기기의 세션을 찾아 열어봅니다. 목록은 메타데이터만 읽고, 대화 본문은 열어볼 때 하나씩만 읽습니다.")
                    .foregroundStyle(.secondary)
                Button("세션 불러오기") { onLoad() }
            }

            if let index {
                TextField("세션 검색 (작업 경로·도구·파일명)", text: $search)
                    .textFieldStyle(.roundedBorder)
                let matched = Self.filter(index.sessions, search: search)
                let shown = Array(matched.prefix(Self.displayLimit))
                if shown.isEmpty {
                    Text(index.sessions.isEmpty
                        ? "표시할 세션이 없습니다."
                        : "검색어와 일치하는 세션이 없습니다.")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { entry in
                    sessionRow(entry)
                }
                if let note = Self.truncationText(
                    matched: matched.count, shown: shown.count,
                    indexed: index.sessions.count, total: index.total
                ) {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            NativeSectionHeader(
                title: "세션 찾아보기",
                subtitle: "이 기기에 남아 있는 AI 세션을 최근 순으로 훑고, 하나를 골라 대화를 읽습니다. 목록은 메타데이터만 읽습니다.",
                value: index.map { "\($0.total)개" } ?? ""
            )
        }
    }

    @ViewBuilder
    private func sessionRow(_ entry: SessionIndexEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayLabel)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                // Only where there is a transcript to open. Editor state
                // is listed -- it is durable local state too -- but it
                // holds no conversation.
                if entry.isReadable {
                    Button(open.contains(entry.source) ? "접기" : "대화 보기") {
                        if open.contains(entry.source) {
                            open.remove(entry.source)
                        } else {
                            open.insert(entry.source)
                            onInspect(entry)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                } else {
                    Text("편집기 상태")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if entry.isReadable, open.contains(entry.source) {
                conversationPanel(entry)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func conversationPanel(_ entry: SessionIndexEntry) -> some View {
        switch conversationStates[conversationKey(entry)] {
        case .loaded(let conversation):
            SessionConversationBody(conversation: conversation)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("다시 시도") { onRetryInspect(entry) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        case .loading, .none:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("대화를 읽는 중…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
