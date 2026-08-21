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
    let project: WorkProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(project.name)을(를) 은퇴하시겠습니까?")
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
                    section("Git", rows: gitRows)
                    section("AI 작업", rows: agentRows)
                    if !project.protectedWorktrees.isEmpty {
                        section("보호할 워크트리", rows: worktreeRows)
                    }
                    section("보존될 것", rows: preservationRows)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("은퇴 준비") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(true)
                    .help("은퇴 실행은 아직 준비되지 않았습니다. 이 검토는 읽기 전용입니다.")
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

    private var gitRows: [(Bool, String)] {
        guard let verdict = project.candidate?.verdict else {
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

    private var agentRows: [(Bool, String)] {
        var rows: [(Bool, String)] = [
            (true, "대화 \(project.conversationCount)개 · \(project.sizeText)")
        ]
        for tool in project.tools {
            let count = project.sessions.filter { $0.tool == tool }.count
            rows.append((true, "\(tool) \(count)개"))
        }
        return rows
    }

    private var worktreeRows: [(Bool, String)] {
        project.protectedWorktrees.map { worktree in
            (false, "\(URL(fileURLWithPath: worktree.path).lastPathComponent) · \(worktree.branch) · \(worktree.reasonText)")
        }
    }

    /// What survives the retirement, said plainly. The whole reason the
    /// continuity work exists is that a repo and its conversations are
    /// deleted by different hands, and only this screen knows both.
    private var preservationRows: [(Bool, String)] {
        guard project.conversationCount > 0 else {
            return [(true, "이 작업에 연결된 AI 대화가 없습니다.")]
        }
        return [
            (true, "대화 \(project.conversationCount)개는 각 제공자 저장소에 그대로 남습니다."),
            (false, "제공자가 자체 보존 기한에 따라 지울 수 있습니다. 남기려면 '보존'으로 내보내세요."),
        ]
    }
}
