import SwiftUI
import MothballCore

/// Everything the agents did, by project.
///
/// This replaces the `AI 세션` and `레포 은퇴` pages, which were one object
/// shown twice through two subsystem lenses. The user's object is a
/// project; sessions, worktrees, git state and retirement eligibility are
/// all facts about it. Retirement in particular is an action on a project,
/// not a place to navigate to -- Finder has no "delete files" tab.
///
/// Two panes here, inside the app's own sidebar: projects and their
/// conversations on the left, the selected conversation on the right.
/// Reaching a conversation is a project click and a title click.
struct WorkPage: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        HSplitView {
            WorkListPane()
                .frame(minWidth: 340, idealWidth: 420)
            WorkDetailPane()
                .frame(minWidth: 320)
        }
        .task { model.prepareWorkScreen() }
        // The git judgment needs the workspace list the audit produces, so
        // on a cold start it cannot be kicked off until that lands. Without
        // this the retirement review never becomes available in the session
        // that first ran the audit.
        .task(id: model.screeReport != nil) { model.prepareWorkScreen() }
        .sheet(item: $model.retirementReview) { project in
            RetirementReviewSheet(project: project)
        }
    }
}

struct WorkListPane: View {
    @EnvironmentObject private var model: ScanModel

    /// Conversation titles shown under a project before it is selected.
    /// Enough to recognise the work, few enough that one project cannot
    /// take the whole viewport.
    static let previewCount = 3

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = model.sessionIndexError {
                WorkNotice(text: error, action: ("다시 시도", { model.refreshSessionIndex() }))
            } else if model.sessionIndexLoading && model.sessionIndex == nil {
                WorkNotice(text: "작업을 읽는 중…", action: nil)
            } else {
                list
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("작업 검색", text: $model.sessionSearch)
                .textFieldStyle(.roundedBorder)
            if let summary = Self.summary(model.workProjects) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// One line saying what the whole list amounts to. The old screens
    /// opened with a worktree inventory, which is coverage rather than a
    /// finding -- "Codex 2,886개" answers no question anyone brought here.
    nonisolated static func summary(_ projects: [WorkProject]) -> String? {
        guard !projects.isEmpty else { return nil }
        let attention = projects.filter(\.needsAttention).count
        let conversations = projects.reduce(0) { $0 + $1.conversationCount }
        var parts = ["작업 \(projects.count)개", "대화 \(conversations)개"]
        if attention > 0 { parts.append("확인 필요 \(attention)개") }
        return parts.joined(separator: " · ")
    }

    nonisolated static func filter(_ projects: [WorkProject], search: String) -> [WorkProject] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return projects }
        let terms = needle.split(separator: " ").map(String.init)
        return projects.compactMap { project in
            // A project matches, or the conversations inside it do -- and
            // when only the conversations match, the row narrows to those.
            if terms.allSatisfy({ project.searchHaystack.contains($0) }) { return project }
            let hits = project.sessions.filter { session in
                terms.allSatisfy { session.searchHaystack.contains($0) }
            }
            guard !hits.isEmpty else { return nil }
            var narrowed = project
            narrowed.sessions = hits
            return narrowed
        }
    }

    private var list: some View {
        let projects = Self.filter(model.workProjects, search: model.sessionSearch)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if projects.isEmpty {
                    WorkNotice(
                        text: model.workProjects.isEmpty
                            ? "아직 확인된 작업이 없습니다."
                            : "검색어와 일치하는 작업이 없습니다.",
                        action: nil
                    )
                }
                ForEach(projects) { project in
                    WorkProjectRow(
                        project: project,
                        expanded: model.selectedProjectID == project.id,
                        previewCount: Self.previewCount
                    )
                    Divider()
                }
            }
        }
    }
}

struct WorkProjectRow: View {
    @EnvironmentObject private var model: ScanModel
    let project: WorkProject
    let expanded: Bool
    let previewCount: Int

    /// How many conversations an expanded project shows before asking.
    ///
    /// Expanding is not "show me everything": a repo here holds 2,767
    /// conversations, and rendering all of them also read all of their
    /// titles -- thousands of transcript reads and thousands of rows from
    /// one click. A page at a time keeps the two-click path and keeps the
    /// title read bounded to what is actually on screen.
    nonisolated static let pageSize = 50

    @State private var page = 1

    private var limit: Int {
        expanded ? Self.pageSize * page : previewCount
    }

    private var shown: [SessionIndexEntry] {
        Array(project.conversations.prefix(limit))
    }

    private var remaining: Int {
        max(0, project.conversationCount - shown.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.selectedProjectID = expanded ? nil : project.id
            } label: {
                summary
            }
            .buttonStyle(.plain)

            // Directly under the project, not after its conversations: a
            // project can hold seventy of them, and an action on the
            // project does not belong at the bottom of a list of its
            // contents.
            if expanded, project.candidate != nil {
                Button("은퇴 검토") { model.retirementReview = project }
                    .buttonStyle(.link)
                    .font(.caption)
                    .padding(.leading, 8)
            }

            ForEach(shown) { session in
                ConversationTitleRow(
                    session: session,
                    title: model.sessionTitles[session.source],
                    selected: model.selectedSessionSource == session.source
                )
            }

            if !expanded, project.conversationCount > previewCount {
                Button("전체 대화 \(project.conversationCount)개 보기") {
                    model.selectedProjectID = project.id
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, 8)
            }
            if expanded, remaining > 0 {
                Button("\(min(remaining, Self.pageSize))개 더 보기 (남은 \(remaining)개)") {
                    page += 1
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.leading, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(expanded ? Color.primary.opacity(0.04) : Color.clear)
        // `task(id:)` rather than `onChange`: expanding recomputes `shown`,
        // and the change handler would otherwise re-request the same three
        // rows it already had while the newly revealed ones sat on
        // "제목을 읽는 중…" forever. One batch, however many rows -- the
        // fetch is a single pass by design.
        .task(id: limit) {
            model.loadSessionTitles(for: shown.map(\.source))
        }
        .onChange(of: expanded) { isOpen in
            // Collapsing resets the window, so reopening does not silently
            // re-render and re-title a thousand rows.
            if !isOpen { page = 1 }
        }
    }

    private var summary: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(project.isUnassigned ? Color.secondary : Color.primary)
                Text(Self.subtitle(project))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !project.gitRisks.isEmpty {
                    Text(project.gitRisks.joined(separator: " · "))
                        .font(.caption)
                        // Weight, not hue: this project reserves chromatic
                        // status colour for states that mean stop, and on a
                        // machine that runs agents daily most rows carry
                        // one of these.
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
            }
            Spacer()
            if project.needsAttention {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(Color.secondary)
                    .accessibilityLabel("확인 필요")
            }
        }
        .contentShape(Rectangle())
    }

    nonisolated static func subtitle(_ project: WorkProject) -> String {
        var parts: [String] = []
        if !project.tools.isEmpty { parts.append(project.tools.joined(separator: " · ")) }
        parts.append("대화 \(project.conversationCount)개")
        if let last = project.lastActive { parts.append(last) }
        parts.append(project.sizeText)
        if !project.protectedWorktrees.isEmpty {
            parts.append("보호할 워크트리 \(project.protectedWorktrees.count)개")
        }
        if !project.unverifiedWorktrees.isEmpty {
            // Not "protected": nobody knows what is in these.
            parts.append("확인 못 한 워크트리 \(project.unverifiedWorktrees.count)개")
        }
        return parts.joined(separator: " · ")
    }
}

/// A conversation, named by what was asked in it. The title is the click
/// target -- the old flow made a person open a session to find out whether
/// it was the one they wanted.
private struct ConversationTitleRow: View {
    @EnvironmentObject private var model: ScanModel
    let session: SessionIndexEntry
    let title: SessionTitle?
    let selected: Bool

    var body: some View {
        Button {
            model.selectedSessionSource = session.source
            model.loadConversation(for: session)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.label(session: session, title: title))
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(Self.detail(session: session, title: title))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(selected ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    nonisolated static func label(session: SessionIndexEntry, title: SessionTitle?) -> String {
        if let text = title?.title, !text.isEmpty { return text }
        return title == nil ? "제목을 읽는 중…" : session.sourceURL.lastPathComponent
    }

    /// A guessed label shown as confidently as a real request is how a
    /// person decides against a conversation they never actually saw.
    nonisolated static func detail(session: SessionIndexEntry, title: SessionTitle?) -> String {
        var parts = [session.tool, session.lastActive]
        if title?.isWeak == true { parts.append("제목 추정") }
        return parts.joined(separator: " · ")
    }
}

private struct WorkDetailPane: View {
    @EnvironmentObject private var model: ScanModel

    private var session: SessionIndexEntry? {
        guard let source = model.selectedSessionSource else { return nil }
        return model.sessionIndex?.sessions.first { $0.source == source }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let session {
                    Text(ConversationTitleRow.label(
                        session: session, title: model.sessionTitles[session.source]))
                        .font(.headline)
                    Text(session.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    detail(for: session)
                } else {
                    WorkAuditSummary()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(session == nil ? 0 : 16)
        }
    }

    @ViewBuilder
    private func detail(for session: SessionIndexEntry) -> some View {
        switch model.conversationState(for: session) {
        case .loaded(let conversation):
            SessionConversationBody(conversation: conversation)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("다시 시도") { model.loadConversation(for: session, retry: true) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        case .loading, .none:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("대화를 읽는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkNotice: View {
    let text: String
    let action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let action {
                Button(action.0) { action.1() }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}


/// What the audit found, shown where nothing else is competing for the
/// pane: before a conversation is picked.
///
/// These are the sections the old `AI 세션` page opened with. They are
/// real findings and real coverage, but putting a worktree inventory
/// first meant fifty-two rows stood between the user and the question
/// they came with. Demoted, not deleted.
private struct WorkAuditSummary: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            if model.screeLoading && model.screeReport == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("작업 감사 실행 중…").foregroundStyle(.secondary)
                }
            } else if let error = model.screeError {
                ScreeNoticeRow(
                    symbol: "exclamationmark.triangle",
                    title: "감사를 실행하지 못했습니다",
                    detail: error,
                    tint: Color.secondary
                )
                Button("다시 시도") { model.refreshScreeReport() }
            } else {
                Section {
                    Text("왼쪽에서 대화를 선택하면 여기에 표시됩니다.")
                        .foregroundStyle(.secondary)
                } header: {
                    NativeSectionHeader(
                        title: "대화",
                        subtitle: "작업별로 최근 대화가 먼저 보입니다. 제목을 누르면 바로 열립니다.",
                        value: ""
                    )
                }
            }

            if let quota = model.timeQuotaSnapshot {
                TimeQuotaSection(snapshot: quota)
            }
            if let report = model.screeReport {
                ScreeExpiringSection(
                    expiring: report.expiring,
                    preserveInFlightSource: model.screePreserveInFlightSource,
                    onPreserve: { model.preserveScreeSession($0) }
                )
                ScreeWorktreeSection(
                    items: report.worktreeItems,
                    protectedCount: report.protectedWorktreeCount
                )
                ScreeLineageSection(
                    summary: report.lineageSummary,
                    unresolvedSessions: report.unresolvedSessions
                )
                ScreeStoresSection(stores: report.stores)
            }
        }
        .macSettingsFormStyle()
        .task { model.refreshTimeQuotaCard() }
    }
}
