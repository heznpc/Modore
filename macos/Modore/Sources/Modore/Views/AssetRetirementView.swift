import SwiftUI
import UniformTypeIdentifiers

struct AssetRetirementView: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    var initialPath: String? = nil
    @State private var choices: [AssetRetirementChoice] = []
    @State private var path = ""
    @State private var plan: AssetRetirementPlan?
    @State private var busy = false
    @State private var cancelRequested = false
    @State private var error = ""
    @State private var excluded: Set<String> = []
    @State private var warningConditions: Set<String> = []
    @State private var confirm = false
    @State private var chooseFolders = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("레포 정리")).font(.title2.bold())
                Spacer()
                Button(L10n.text("이전 거래 불러오기")) { perform(["action": "latest"]) }.disabled(busy)
                Button(L10n.text("닫기")) { dismiss() }.disabled(busy)
            }
            Text(L10n.text("GitHub 아카이브와 로컬 삭제를 선택하세요. ignored 자료는 기본 보존합니다."))
                .foregroundStyle(.secondary)
            HStack {
                TextField(L10n.text("레포 폴더 절대 경로"), text: $path).textFieldStyle(.roundedBorder)
                    .onSubmit { addPath() }
                Button(L10n.text("추가")) { addPath() }.disabled(busy || path.isEmpty)
                Button(L10n.text("폴더 선택…")) { chooseFolders = true }.disabled(busy)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach($choices) { $choice in
                        VStack(alignment: .leading) {
                            HStack {
                                Text(choice.path).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button(L10n.text("제외")) { choices.removeAll { $0.id == choice.id }; plan = nil }
                            }
                            HStack {
                                Toggle(L10n.text("GitHub 아카이브"), isOn: $choice.archive)
                                Toggle(L10n.text("로컬 삭제"), isOn: $choice.local)
                                Toggle(L10n.text("재생성 ignored도 삭제"), isOn: $choice.deleteGenerated)
                            }
                        }
                    }
                    .disabled(busy || plan != nil)
                    if let plan {
                        ForEach(plan.items) { item in itemView(item) }
                        if !plan.receipt.isEmpty {
                            Text(L10n.format("기록: %@", String(describing: plan.receipt))).font(.caption).textSelection(.enabled)
                        }
                    }
                }
            }
            if !error.isEmpty { Text(L10n.message(error)).foregroundStyle(.red).textSelection(.enabled) }
            Divider()
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("처리 중 · 결과는 항목별로 기록됩니다"))
                    Spacer()
                    if let plan { Button(L10n.text("이후 작업 취소")) { cancelRequested = true; try? AssetRetirementService.cancel(plan.id) } }
                } else if let plan {
                    Text(L10n.text("격리 없이 삭제 · 파일 크기와 실제 확보량은 다릅니다")).font(.caption)
                    Spacer()
                    Button(L10n.text("새 계획")) { self.plan = nil; excluded = []; warningConditions = [] }
                    Button(L10n.text("선택 승인·실행")) { confirm = true }
                        .disabled(eligible(plan).isEmpty)
                    Button(L10n.text("승인된 항목 이어서 실행")) {
                        perform(["action": "execute", "transaction": plan.id, "ids": eligible(plan)])
                    }.disabled(!plan.items.contains { $0.approved && !$0.isFinished })
                } else {
                    Spacer()
                    Button(L10n.text("삭제·보존 목록 확인")) {
                        perform(["action": "preview", "items": choices.filter { $0.archive || $0.local }.map(\.request)])
                    }.buttonStyle(.borderedProminent).disabled(choices.isEmpty)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 920, minHeight: 560, idealHeight: 720)
        .fileImporter(isPresented: $chooseFolders, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            do {
                for url in try result.get() { choices.append(.init(path: url.path)) }
                plan = nil
            } catch { self.error = error.localizedDescription }
        }
        .task(id: busy) {
            guard busy, let id = plan?.id else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    let progress = try await AssetRetirementService.invoke(root: model.projectRoot,
                        request: ["action": "status", "transaction": id])
                    guard !Task.isCancelled, busy else { return }
                    plan = progress
                } catch { return }
            }
        }
        .interactiveDismissDisabled(busy)
        .onAppear { if choices.isEmpty, let initialPath { choices = [.init(path: initialPath)] } }
        .confirmationDialog(L10n.text("선택한 레포의 작업을 실행하시겠습니까? 로컬 삭제는 되돌릴 수 없습니다."), isPresented: $confirm) {
            Button(L10n.text("선택 승인 후 실행"), role: .destructive) { approveAndExecute() }
            Button(L10n.text("취소"), role: .cancel) {}
        } message: {
            if let plan {
                Text(plan.items.filter { eligible(plan).contains($0.id) }.map {
                    L10n.format("%@\n%@%@ · 보존 %@", String(describing: $0.path), String(describing: $0.archive ? L10n.format("GitHub %@ 아카이브 ", String(describing: $0.remote?.full_name ?? "")) : ""), String(describing: $0.local ? L10n.text("로컬 삭제") : ""), String(describing: size($0.keepBytes)))
                }.joined(separator: "\n\n"))
            }
        }
    }

    private func addPath() {
        let value = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        choices.append(.init(path: value)); path = ""; plan = nil
    }

    private func eligible(_ plan: AssetRetirementPlan) -> [String] {
        plan.items.filter { item in
            !item.isFinished && !item.changed && !excluded.contains(item.id) && !item.warnings.indices.contains {
                warningConditions.contains("\(item.id):\($0)")
            }
        }.map(\.id)
    }

    @ViewBuilder private func itemView(_ item: AssetRetirementItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(item.path, isOn: Binding(get: { !excluded.contains(item.id) }, set: {
                if $0 { excluded.remove(item.id) } else { excluded.insert(item.id) }
            })).font(.headline)
            Text((item.archive ? L10n.text("GitHub 아카이브 · ") : "") + L10n.text(item.local ? "로컬 삭제" : "로컬 유지"))
            Text(L10n.format("삭제 대상 %@ · 보존 %@ · 재생성 ignored %@", String(describing: size(item.deleteBytes)), String(describing: size(item.keepBytes)), String(describing: size(item.generatedBytes))))
                .font(.callout)
            if let project = model.workProjects.first(where: { $0.path == item.path }) {
                Text(L10n.format("기존 작업 목록의 연결: 대화 %@개 · 워크트리 %@개 (전체 참조 확인 아님)", String(describing: project.sessions.count), String(describing: project.worktrees.count)))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(Array(project.worktrees.enumerated()), id: \.offset) { _, worktree in
                    Text(L10n.format("참조: %@ · %@", String(describing: worktree.path), String(describing: worktree.branch)))
                        .font(.caption).textSelection(.enabled)
                }
            }
            DisclosureGroup(L10n.text("위험 경고 · 조건을 체크하면 해당 레포를 제외합니다")) {
                ForEach(Array(item.warnings.enumerated()), id: \.offset) { index, warning in
                    Toggle(L10n.message(warning), isOn: Binding(get: { warningConditions.contains("\(item.id):\(index)") }, set: {
                        if $0 { warningConditions.insert("\(item.id):\(index)") }
                        else { warningConditions.remove("\(item.id):\(index)") }
                    })).font(.caption)
                }
            }
            DisclosureGroup(L10n.text("삭제·보존 파일 (전체 목록은 거래 기록)")) {
                ForEach(item.files.prefix(200)) { file in
                    HStack {
                        Text(file.keep ? L10n.text("보존") : L10n.text("삭제"))
                        Text(file.path).textSelection(.enabled)
                        Spacer()
                        if file.generated { Text(L10n.text("재생성 가능")).foregroundStyle(.secondary) }
                        Text(size(file.bytes))
                    }.font(.caption)
                }
            }
            if item.archive {
                if let remote = item.remote { Text("GitHub: \(remote.full_name)").font(.caption.monospaced()) }
                Text(L10n.format("GitHub 요청: %@ · 사후 검증: %@", String(describing: status(item.archiveMutation)), String(describing: status(item.archiveVerification))))
            }
            if item.local {
                Text(L10n.format("삭제 실행: %@ (%@개) · 사후 검증: %@", String(describing: status(item.localMutation)), String(describing: item.deletedCount), String(describing: status(item.localVerification))))
                if let before = item.beforeFree, let after = item.afterFree {
                    Text(L10n.format("실제 여유: %@ → %@ · 순변화 %@%@", String(describing: size(before)), String(describing: size(after)), String(describing: after >= before ? "+" : "−"), String(describing: size(abs(after - before)))))
                } else { Text(L10n.text("실제 여유 변화: 미측정")).foregroundStyle(.secondary) }
            }
            if !item.error.isEmpty { Text(L10n.message(item.error)).foregroundStyle(.orange) }
            if item.changed, let plan {
                Button(L10n.text("변경된 대상 다시 확인")) {
                    perform(["action": "refresh", "transaction": plan.id, "ids": [item.id]])
                }
            }
            Divider()
        }.disabled(busy)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
    private func status(_ value: String) -> String {
        ["pending": L10n.text("대기"), "attempting": L10n.text("시도됨"), "succeeded": L10n.text("성공"), "verified": L10n.text("확인됨"), "partial": L10n.text("부분 처리"), "failed": L10n.text("실패")][value] ?? value
    }
    private func perform(_ request: [String: Any]) {
        cancelRequested = false
        if request["action"] as? String == "execute", let id = request["transaction"] as? String {
            AssetRetirementService.resetCancellation(id)
        }
        busy = true; error = ""
        let mutating = request["action"] as? String == "execute"
        if mutating { model.beginApplicationDestructiveTransaction() }
        Task {
            defer {
                busy = false
                if mutating { model.finishApplicationDestructiveTransaction() }
            }
            do { plan = try await AssetRetirementService.invoke(root: model.projectRoot, request: request) }
            catch { self.error = error.localizedDescription }
        }
    }
    private func approveAndExecute() {
        guard let plan else { return }
        let ids = eligible(plan)
        cancelRequested = false
        AssetRetirementService.resetCancellation(plan.id)
        busy = true; error = ""
        model.beginApplicationDestructiveTransaction()
        Task {
            defer { busy = false; model.finishApplicationDestructiveTransaction() }
            do {
                self.plan = try await AssetRetirementService.invoke(root: model.projectRoot,
                    request: ["action": "approve", "transaction": plan.id, "ids": ids])
                guard !cancelRequested else { return }
                self.plan = try await AssetRetirementService.invoke(root: model.projectRoot,
                    request: ["action": "execute", "transaction": plan.id, "ids": ids])
            } catch { self.error = error.localizedDescription }
        }
    }
}
