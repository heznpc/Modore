import SwiftUI
import MothballCore

/// Retiring a project, as a decision rather than a destination.
///
/// This is what the `레포 은퇴` page became. That page could not even start
/// without the session audit having run first, which is the shape of a
/// step in a workflow, not a peer in a sidebar. As a sheet it can state
/// the whole case at once -- git state, what the agents left, what a
/// retirement would preserve -- which is what someone actually needs in
/// front of them before deciding.
///
/// Read-only, exactly as the page was: nothing here compresses, moves or
/// deletes anything.
struct RetirementReviewSheet: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    /// Resolved from the model on every render rather than captured once,
    /// so counts that arrive after the sheet opens are the counts shown.
    let projectID: String

    private var project: WorkProject? {
        model.workProjects.first { $0.id == projectID }
    }

    var body: some View {
        if let project {
            content(project)
        } else {
            // The project stopped existing while its sheet was open -- a
            // rescan that no longer sees it, most likely. Saying so beats
            // an empty sheet that looks like a clean bill of health.
            VStack(spacing: 12) {
                Text("이 작업을 더 이상 찾을 수 없습니다.")
                    .foregroundStyle(.secondary)
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(32)
            .frame(minWidth: 320, minHeight: 160)
        }
    }

    @ViewBuilder
    private func content(_ project: WorkProject) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(project.name) 은퇴 가능성 검토")
                    .font(.title3.weight(.semibold))
                Text(project.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section("Git", rows: gitRows(project))
                    section("AI 작업", rows: agentRows(project))
                    if !project.protectedWorktrees.isEmpty {
                        section("보호할 워크트리", rows: worktreeRows(project))
                    }
                    if !project.unverifiedWorktrees.isEmpty {
                        section("확인 못 한 워크트리", rows: unverifiedRows(project))
                    }
                    section("보존될 것", rows: preservationRows(project))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            // One button, because there is only one thing to do here. A
            // disabled primary action under a "은퇴하시겠습니까?" title
            // reads as a confirmation dialog that refuses to confirm; this
            // screen reviews, and says so.
            HStack {
                Text("이 검토는 읽기 전용입니다. 은퇴 실행은 아직 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
    }

    @ViewBuilder
    private func section(_ title: String, rows: [(Bool, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Weight and glyph, not hue -- the project reserves
                    // chromatic status colour for states that mean stop.
                    Image(systemName: row.0 ? "checkmark" : "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.secondary)
                        .frame(width: 14)
                    Text(row.1)
                        .font(.callout)
                        .fontWeight(row.0 ? .regular : .medium)
                        .foregroundStyle(row.0 ? Color.secondary : Color.primary)
                }
            }
        }
    }

    private func gitRows(_ project: WorkProject) -> [(Bool, String)] {
        // The assessment, not the candidate: they are the same object here
        // (the sheet only opens for an eligible repo) but the git state is
        // a fact about the repo rather than about its eligibility.
        guard let verdict = project.assessment?.verdict else {
            return [(false, "이 저장소의 git 상태를 아직 확인하지 못했습니다.")]
        }
        return verdict.reasons.map { reason in
            switch reason {
            case .fullyPushed: return (true, "원격에 모두 반영됨")
            case .dormant(let days): return (true, "\(days)일간 미사용")
            case .recentActivity(let days): return (false, "최근 활동 \(days)일 전")
            case .dirtyWorkingTree: return (false, "커밋 안 된 변경 있음")
            case .unpushedCommits(let count): return (false, "미푸시 커밋 \(count)개")
            case .noRemoteConfigured: return (false, "원격 저장소 없음")
            case .noUpstreamConfigured: return (false, "업스트림 미설정")
            case .noCommitsYet: return (false, "커밋 없음")
            }
        }
    }

    /// What the binder found, not what the index happened to group here.
    ///
    /// The index groups by recorded workspace, which is a good way to
    /// browse and the wrong authority for a retirement decision. The
    /// binder answers a different question -- which sessions are bound to
    /// this repo, on what evidence, and whether it managed to look at
    /// everything -- and that is the answer this screen exists to show.
    private func agentRows(_ project: WorkProject) -> [(Bool, String)] {
        guard let continuity = project.candidate?.continuity else {
            return [(false, "이 저장소의 AI 대화 연결을 아직 확인하지 않았습니다.")]
        }
        switch continuity {
        case .notAssessed:
            return [(false, project.candidate?.continuityDiagnostic
                .map { "AI 대화 연결 확인 실패 · \($0)" } ?? "AI 대화 연결을 확인하지 못했습니다.")]
        case .assessedNoSessions:
            return [(true, "이 저장소에 연결된 AI 대화가 없습니다. (전체 확인됨)")]
        case .bindings(let bindings, let coverage):
            return bindingRows(bindings, coverage: coverage)
        case .sealed(let bundle, let coverage):
            return [(true, "AI 대화 \(bundle.sessions.count)개가 봉인되었습니다.")]
                + coverageRows(coverage)
        }
    }

    private func bindingRows(
        _ bindings: [SessionBinding], coverage: BindingCoverage
    ) -> [(Bool, String)] {
        let bytes = ByteCountFormatter.string(
            fromByteCount: bindings.reduce(0) { $0 + $1.sizeBytes }, countStyle: .file)
        var rows: [(Bool, String)] = [(true, "연결된 대화 \(bindings.count)개 · \(bytes)")]
        // Grouped by how firmly each is bound. "Bound because a path
        // appeared in the transcript" and "bound because the provider
        // recorded the remote" are not the same claim.
        for confidence in [BindingConfidence.high, .medium, .low] {
            let matching = bindings.filter { $0.confidence == confidence }
            guard !matching.isEmpty else { continue }
            rows.append((confidence != .low,
                         "\(Self.confidenceLabel(confidence)) \(matching.count)개"))
        }
        return rows + coverageRows(coverage)
    }

    /// A partial pass must never round up to a conclusion. Sealing or
    /// retiring on what an incomplete scan happened to find preserves
    /// those and abandons the rest, which is worse than refusing because
    /// it looks like success.
    private func coverageRows(_ coverage: BindingCoverage) -> [(Bool, String)] {
        coverage == .complete
            ? [(true, "모든 세션 저장소를 확인했습니다.")]
            : [(false, "일부 저장소를 확인하지 못했습니다. 이 숫자는 하한입니다.")]
    }

    private static func confidenceLabel(_ confidence: BindingConfidence) -> String {
        switch confidence {
        case .high: return "확실하게 연결됨"
        case .medium: return "보통 확신"
        case .low: return "약한 근거"
        }
    }

    private func worktreeRows(_ project: WorkProject) -> [(Bool, String)] {
        project.protectedWorktrees.map { worktree in
            (false, "\(URL(fileURLWithPath: worktree.path).lastPathComponent) · \(worktree.branch) · \(worktree.reasonText)")
        }
    }

    /// Unreadable is not safe, and it is not protected either -- calling
    /// it protected claims knowledge nobody has.
    private func unverifiedRows(_ project: WorkProject) -> [(Bool, String)] {
        project.unverifiedWorktrees.map { worktree in
            (false, "\(URL(fileURLWithPath: worktree.path).lastPathComponent) · \(worktree.branch) · 상태를 읽지 못했습니다")
        }
    }

    /// What survives the retirement, said plainly. The whole reason the
    /// continuity work exists is that a repo and its conversations are
    /// deleted by different hands, and only this screen knows both.
    private func preservationRows(_ project: WorkProject) -> [(Bool, String)] {
        guard let continuity = project.candidate?.continuity else {
            return [(false, "무엇이 보존될지 판단할 근거가 아직 없습니다.")]
        }
        // "Nothing would be lost" is a conclusion, and only a complete
        // pass is allowed to reach it.
        if case .assessedNoSessions = continuity {
            return [(true, "이 저장소에 연결된 AI 대화가 없습니다. 잃을 것이 없습니다.")]
        }
        guard case .bindings(let bindings, let coverage) = continuity else {
            return [(true, "봉인된 대화는 아카이브와 함께 보존됩니다.")]
        }
        var rows: [(Bool, String)] = [
            (true, "대화 \(bindings.count)개는 각 제공자 저장소에 그대로 남습니다."),
            (false, "제공자가 자체 보존 기한에 따라 지울 수 있습니다. 남기려면 '보존'으로 내보내세요."),
        ]
        if coverage != .complete {
            rows.append((false, "확인하지 못한 저장소가 있어 여기 없는 대화가 더 있을 수 있습니다."))
        }
        return rows
    }
}
