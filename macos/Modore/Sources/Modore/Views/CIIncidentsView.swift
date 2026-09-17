import AppKit
import SwiftUI

struct CIIncidentsView: View {
    @EnvironmentObject private var model: ScanModel
    @EnvironmentObject private var ci: CIWatchService
    @Environment(\.dismiss) private var dismiss
    @State private var filter = "open"
    @State private var repository = ""
    @State private var copied: String?

    private var issues: [CIIncident] {
        (ci.snapshot?.incidents ?? []).filter { filter == "all" || $0.state == filter }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(L10n.text("CI 문제"), systemImage: "checkmark.circle.trianglebadge.exclamationmark")
                    .font(.title2.bold())
                Spacer()
                if ci.busy { ProgressView().controlSize(.small) }
                Button(L10n.text("상태 새로고침")) { Task { await ci.refresh(model: model) } }.disabled(ci.busy)
                Button(L10n.text("닫기")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                TextField(L10n.text("저장소 추가 (owner/name)"), text: $repository).textFieldStyle(.roundedBorder)
                    .onSubmit { addRepository() }
                Button(L10n.text("추가·조회")) { addRepository() }.disabled(ci.busy || repository.isEmpty)
            }
            Toggle(L10n.text("앱 실행 중 5분마다 확인하고 새 문제·복구만 알림"), isOn: Binding(
                get: { ci.enabled }, set: { value in Task { await ci.setEnabled(value, model: model) } }
            ))
            HStack {
                Picker(L10n.text("표시"), selection: $filter) {
                    Text(L10n.text("미해결")).tag("open")
                    Text(L10n.text("복구됨")).tag("recovered")
                    Text(L10n.text("전체 기록")).tag("all")
                }.pickerStyle(.segmented).frame(maxWidth: 360)
                Spacer()
                Text(L10n.format("미해결 %d건", ci.snapshot?.open.count ?? 0)).font(.headline)
            }
            if !ci.message.isEmpty { Text(ci.message).foregroundStyle(.orange).textSelection(.enabled) }
            if let error = ci.snapshot?.discoveryError {
                Label(L10n.text("GitHub 알림 조회 미확인") + ": " + error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if ci.snapshot?.checkedAt == nil {
                        Text(L10n.text("GitHub CLI 로그인 후 새로고침하세요. CI 알림과 로컬 프로젝트에서 저장소를 찾습니다."))
                            .foregroundStyle(.secondary).padding(.vertical, 40)
                    } else if issues.isEmpty {
                        Text(L10n.text("현재 조회 범위에서 표시할 CI 문제가 없습니다."))
                            .foregroundStyle(.secondary).padding(.vertical, 30)
                    }
                    ForEach(issues) { issue in card(issue) }
                    ForEach(ci.snapshot?.repositories.filter { $0.error != nil } ?? []) { repo in
                        Label(repo.repo + ": " + (repo.error ?? ""), systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange).font(.caption).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Text(L10n.text("최대 24개 저장소의 최근 50회 실행을 확인합니다. 첫 수집은 알리지 않으며, 조회 실패·취소는 복구로 처리하지 않습니다. GitHub 메일 설정은 별도입니다."))
                .font(.caption).foregroundStyle(.secondary)
            if let stamp = ci.snapshot?.checkedAt {
                Text(L10n.text("마지막 확인") + ": " + stamp).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(22).frame(minWidth: 760, idealWidth: 900, minHeight: 600, idealHeight: 720)
            .task { await ci.load(root: model.projectRoot) }
    }

    private func addRepository() {
        let requested = repository
        Task { await ci.refresh(model: model, repository: requested) }
    }

    private func card(_ issue: CIIncident) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: issue.state == "recovered" ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .foregroundStyle(issue.state == "recovered" ? .green : .orange)
                Text(issue.repo).font(.headline)
                Spacer()
                Text(issue.statusTitle).font(.caption)
            }
            Text(issue.workflow + " · " + issue.branch + " · " + issue.event).font(.subheadline)
            Text(L10n.text("마지막 확인") + ": " + issue.lastSeen).font(.caption).foregroundStyle(.secondary)
            Text(issue.steps.joined(separator: "\n")).font(.callout).textSelection(.enabled)
            Text(L10n.format("관측 실패 %d회 · 최근 연속 실패 %d회", issue.observedFailures, issue.streak))
                .font(.caption).foregroundStyle(.secondary)
            if issue.evidence != "log" {
                Text(L10n.text("실패 단계 기준 묶음 · 상세 원인은 로그 확인 필요"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !issue.excerpt.isEmpty {
                DisclosureGroup(L10n.text("실패 근거")) {
                    Text(issue.excerpt).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                if let url = issue.runURL { Link(L10n.text("GitHub 실행 열기"), destination: url) }
                if let recovery = issue.verifiedRecoveryURL { Link(L10n.text("복구 실행 확인"), destination: recovery) }
                Spacer()
                Button(copied == issue.id ? L10n.text("복사됨") : L10n.text("에이전트 수정 요청 복사")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(issue.repairPrompt, forType: .string)
                    copied = issue.id
                }
            }
            let paths = ci.snapshot?.projects[issue.repo] ?? []
            let projects = model.workProjects.filter { project in paths.contains(project.path) }
            if !projects.isEmpty {
                HStack {
                    Text(L10n.text("관련 작업")).font(.caption).foregroundStyle(.secondary)
                    ForEach(projects) { project in
                        Button(project.name) { model.selectedProjectID = project.id; dismiss() }
                    }
                }
            }
            if let repo = ci.snapshot?.repositories.first(where: { $0.repo == issue.repo }), repo.error != nil {
                Text(L10n.text("최신 상태 조회 실패 · 이전 기록입니다")).font(.caption).foregroundStyle(.orange)
            }
        }.padding(16).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }
}
