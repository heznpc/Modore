import AppKit
import SwiftUI

@MainActor
struct SessionRecoverySheet: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var plan: SessionRecoveryPlan?
    @State private var selected: Set<String> = []
    @State private var destination: URL?
    @State private var consent = false
    @State private var busy = false
    @State private var cancelling = false
    @State private var phase = ""
    @State private var error: String?
    @State private var receipt: SessionRecoveryReceipt?
    @State private var showingResume = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("백업·이전")).font(.title2.bold())
                    Text(L10n.text("Git 연결 여부와 관계없이 선택한 앱의 세션 원본과 상태 자료를 함께 보관합니다."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.text("프로젝트 코드·Git 저장소·미커밋 변경은 별도 백업이 필요합니다."))
                        .font(.callout).foregroundStyle(.secondary)
                    Text(L10n.text("앱 전체 복원이나 대화 재개 성공을 보장하지 않습니다. Codex·Claude Code는 별도 CLI 재개 준비를 지원합니다."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text("닫기")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(busy || showingResume)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let plan { planContent(plan) }
                    else if !busy {
                        Button(L10n.text("보관할 원본 다시 확인")) { run(.plan) }
                    }
                    if let receipt { receiptContent(receipt) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L10n.text("기존 백업 폴더 확인…")) { chooseBundle() }
                    .disabled(busy).accessibilityIdentifier("session-recovery-verify")
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text(cancelling ? L10n.text("중단 후 부분 파일을 정리하고 있습니다…") : phase)
                        .font(.callout)
                    Button(L10n.text("중단")) {
                        cancelling = true
                        model.cancelSessionRecovery()
                    }.disabled(cancelling).accessibilityIdentifier("session-recovery-cancel")
                }
            }
        }
        .padding(24).frame(width: 780, height: 710)
        .interactiveDismissDisabled(busy || showingResume)
        .task { if plan == nil { run(.plan) } }
        .sheet(isPresented: $showingResume) {
            if let restored = receipt?.restoredRoot {
                SessionResumeSheet(restoredRoot: URL(fileURLWithPath: restored))
            }
        }
    }

    private func planContent(_ plan: SessionRecoveryPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("보관할 원본")).font(.headline)
                Spacer()
                Button(L10n.text("전체 선택")) { selected = plan.availableIDs }.disabled(busy)
                Button(L10n.text("다시 확인")) { run(.plan) }.disabled(busy)
            }
            ForEach(plan.items) { item in
                HStack(alignment: .top, spacing: 12) {
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: {
                        if $0 { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.provider + " · " + L10n.message(item.label)).fontWeight(.medium)
                            Text((item.source as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                            if !item.reason.isEmpty {
                                Text(L10n.message(item.reason)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.disabled(busy || !item.available)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(item.available ? size(item.bytes) : L10n.text("확인 필요"))
                        Text(L10n.format("%@개 파일", String(item.fileCount))).font(.caption).foregroundStyle(.secondary)
                    }.monospacedDigit()
                }
            }
            if plan.items.isEmpty {
                Text(L10n.text("이 Mac에서 보관할 세션 원본을 찾지 못했습니다. 기존 백업은 아래에서 확인할 수 있습니다."))
                    .foregroundStyle(.secondary)
            }
            if !plan.coverage.isEmpty {
                DisclosureGroup(L10n.text("프로젝트 연결과 다른 Mac에서의 사용")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.text("Git 연결은 기록된 저장소와의 관계입니다. 커밋되었거나 원격에 백업됐다는 뜻은 아닙니다."))
                        ForEach(plan.coverage) { item in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.provider).fontWeight(.medium)
                                Text(L10n.format("기록 %@개 · Git 연결 %@ · 폴더 연결 %@ · 연결 미확인 %@",
                                                 String(item.recordCount), String(item.gitLinkedCount),
                                                 String(item.folderLinkedCount), String(item.unassignedCount)))
                                Text(L10n.message(item.resumeSupport)).foregroundStyle(.secondary)
                            }
                        }
                        Text(L10n.text("앱 상태 DB도 선택된 원본에 포함해 보존합니다. 다른 Mac의 실행 중인 앱이나 로그인 상태에 자동으로 덮어쓰지 않습니다."))
                    }.font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }
            }
            if !plan.excluded.isEmpty {
                DisclosureGroup(L10n.text("포함하지 않는 자료")) {
                    ForEach(Array(plan.excluded.enumerated()), id: \.offset) { _, value in
                        Text(L10n.message(value)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                Label(L10n.message(warning), systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Toggle(L10n.text("대화·코드·비밀값이 포함될 수 있으며, 이 백업은 암호화되지 않음을 확인했습니다."), isOn: $consent)
                .font(.callout).disabled(busy)
            HStack {
                Button(L10n.text("외장 SSD의 저장 폴더 선택…")) {
                    if let folder = SessionRecoveryPanels.directory(title: L10n.text("백업을 보관할 폴더"),
                        message: L10n.text("선택한 폴더 아래 Backup/날짜/새 백업 폴더를 만듭니다.")) {
                        destination = SessionRecoveryOperation.backupDestination(in: folder)
                    }
                }.disabled(busy).accessibilityIdentifier("session-recovery-destination")
                Spacer()
                Text(L10n.format("선택 %@개 · %@", String(selected.intersection(plan.availableIDs).count), size(plan.selectedBytes(selected))))
                    .font(.callout).monospacedDigit()
            }
            if let destination {
                Text(destination.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                Button(L10n.text("선택한 원본 백업·검증")) {
                    run(.backup(destination: destination, itemIDs: selected.intersection(plan.availableIDs).sorted()))
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || !consent || selected.intersection(plan.availableIDs).isEmpty)
                .accessibilityIdentifier("session-recovery-backup")
            }
        }
    }

    private func receiptContent(_ receipt: SessionRecoveryReceipt) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Label(receipt.status == "restored" ? L10n.text("새 폴더의 복원 파일 검증 성공") : L10n.text("백업 파일 검증 성공"), systemImage: "checkmark.shield")
                .font(.headline)
            Text(receipt.summary)
            Text(receipt.providers.joined(separator: " · ")).font(.caption)
            Text(receipt.restoredRoot ?? receipt.bundle).font(.caption.monospaced()).textSelection(.enabled)
            Text(L10n.text("SHA-256은 파일 무결성을 확인합니다. 앱 로그인과 실제 세션 재개는 별도로 확인해야 합니다."))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(receipt.warnings.enumerated()), id: \.offset) { _, warning in
                Text(L10n.message(warning)).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(L10n.text("Finder에서 보기")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: receipt.restoredRoot ?? receipt.bundle)])
                }
                Button(L10n.text("새 폴더로 복원·검증…")) {
                    if let parent = SessionRecoveryPanels.directory(title: L10n.text("복원할 새 폴더의 위치"),
                        message: L10n.text("선택한 위치에 새 폴더를 만들며 기존 앱 자료는 덮어쓰지 않습니다.")) {
                        run(.restore(bundle: URL(fileURLWithPath: receipt.bundle), destination: parent.appendingPathComponent("Modore-Restored-\(UUID().uuidString.prefix(8))")))
                    }
                }.accessibilityIdentifier("session-recovery-restore")
                if receipt.restoredRoot != nil {
                    Button(L10n.text("이어서 쓰기 준비…")) { showingResume = true }
                        .accessibilityIdentifier("session-recovery-resume")
                }
            }.disabled(busy)
        }
    }

    private func chooseBundle() {
        if let bundle = SessionRecoveryPanels.directory(title: L10n.text("기존 백업 폴더 확인"),
            message: L10n.text("Modore가 만든 백업 폴더를 선택하세요.")) {
            run(.verify(bundle: bundle))
        }
    }

    private func run(_ operation: SessionRecoveryOperation) {
        guard !busy else { return }
        busy = true
        cancelling = false
        error = nil
        switch operation {
        case .plan: phase = L10n.text("세션 원본과 연결 정보를 확인하고 있습니다…")
        case .backup: phase = L10n.text("원본 복사·SHA-256 검증 중…"); receipt = nil
        case .verify: phase = L10n.text("백업의 SHA-256을 검증하고 있습니다…"); receipt = nil
        case .restore: phase = L10n.text("새 폴더 복원·SHA-256 검증 중…"); receipt = nil
        }
        model.startSessionRecovery(operation: operation) { result in
            busy = false
            cancelling = false
            switch result {
            case .success(.plan(let value)):
                plan = value
                selected = value.availableIDs
            case .success(.receipt(let value)):
                receipt = value
                AccessibilityAnnouncer.announce(L10n.text("백업·복원 파일의 무결성을 확인했습니다."))
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

@MainActor
private struct SessionResumeSheet: View {
    let restoredRoot: URL
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: SessionResumeList?
    @State private var selectedID = ""
    @State private var workspace: URL?
    @State private var providerHome: URL?
    @State private var prepared: SessionResumePlan?
    @State private var busy = false
    @State private var cancelling = false
    @State private var error: String?

    private var candidate: SessionResumeCandidate? {
        inventory?.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.text("다른 Mac에서 이어서 쓰기 준비")).font(.title2.bold())
                Spacer()
                Button(L10n.text("닫기")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
            }
            Text(L10n.text("앱과 CLI 설치·로그인은 이 Mac에서 별도로 필요합니다. 복원한 기록을 새 앱 환경에 준비하고, 직접 실행할 재개 명령을 만듭니다."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L10n.text("프로젝트 코드·Git 저장소·미커밋 변경은 별도 백업이 필요합니다."))
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let inventory { selectionContent(inventory) }
                    if let prepared { preparedContent(prepared) }
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red).textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(L10n.text("복원본 세션 다시 확인")) { load() }.disabled(busy)
                Spacer()
                if busy {
                    ProgressView().controlSize(.small)
                    Text(cancelling ? L10n.text("작업을 중단하고 있습니다…") : L10n.text("세션 재개를 준비하고 있습니다…"))
                        .font(.callout)
                    Button(L10n.text("중단")) {
                        cancelling = true
                        model.cancelSessionRecovery()
                    }.disabled(cancelling)
                }
            }
        }
        .padding(24).frame(width: 740, height: 650)
        .interactiveDismissDisabled(busy)
        .task { load() }
        .onChange(of: selectedID) { _ in prepared = nil; providerHome = nil }
    }

    private func selectionContent(_ inventory: SessionResumeList) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if inventory.sessions.isEmpty {
                Text(L10n.text("이 복원본에서 재개를 준비할 수 있는 세션을 찾지 못했습니다. 원본 파일은 그대로 보관됩니다."))
            } else {
                Picker(L10n.text("이어서 쓸 세션"), selection: $selectedID) {
                    ForEach(inventory.sessions) { session in
                        Text(session.label).tag(session.id)
                    }
                }.disabled(busy).accessibilityIdentifier("session-resume-picker")
                if let candidate, let oldWorkspace = candidate.workspace, !oldWorkspace.isEmpty {
                    Text(L10n.format("기록된 작업 폴더: %@", oldWorkspace))
                        .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Button(L10n.text("이 Mac의 작업 폴더 선택…")) {
                    if let value = SessionRecoveryPanels.directory(title: L10n.text("세션에서 사용할 작업 폴더"),
                        message: L10n.text("별도로 복원한 프로젝트 폴더를 선택하세요. 파일 없는 대화 작업은 빈 폴더를 사용할 수 있습니다.")) {
                        workspace = value; prepared = nil
                    }
                }.disabled(busy)
                if let workspace { pathText(workspace.path) }
                Button(L10n.text("새 앱 환경을 만들 위치 선택…")) {
                    if let value = SessionRecoveryPanels.directory(title: L10n.text("격리된 앱 환경의 위치"),
                        message: L10n.text("이 위치에 새 폴더를 만듭니다. 기존 앱 기록·상태 DB·로그인 정보를 덮어쓰지 않습니다.")) {
                        providerHome = value.appendingPathComponent("Modore-\(candidate?.provider ?? "Session")-\(UUID().uuidString.prefix(8))")
                        prepared = nil
                    }
                }.disabled(busy || candidate == nil)
                if let providerHome { pathText(providerHome.path) }
                Button(L10n.text("격리된 재개 환경 준비")) { prepare() }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || candidate == nil || workspace == nil || providerHome == nil || prepared != nil)
                    .accessibilityIdentifier("session-resume-prepare")
            }
            ForEach(Array(inventory.warnings.enumerated()), id: \.offset) { _, value in
                Text(L10n.message(value)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func preparedContent(_ value: SessionResumePlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text(value.status == "ready_to_try" ? L10n.text("재개 시도 준비됨 · 실제 재개 미검증") : L10n.text("이 세션의 자동 재개 준비는 지원되지 않습니다."))
                .font(.headline)
            Text(L10n.text("파일 복원과 재개 명령 준비를 마쳤더라도, CLI에서 기록이 열리고 작업을 계속할 수 있는지는 실행 후 확인해야 합니다."))
                .font(.callout).foregroundStyle(.secondary)
            ForEach(Array(value.limitations.enumerated()), id: \.offset) { _, limitation in
                Text(L10n.message(limitation)).font(.caption).foregroundStyle(.secondary)
            }
            if value.status == "ready_to_try" {
                Text(value.shellCommand).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Button(L10n.text("재개 명령 복사")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(value.shellCommand, forType: .string)
                    }.accessibilityIdentifier("session-resume-copy")
                    Button(L10n.text("터미널 열기")) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                    }
                }
                Text(L10n.text("복사한 명령의 새 환경에서 로그인해야 합니다. 평소 터미널의 로그인과 별개이며, Modore는 자동으로 LLM 요청을 보내지 않습니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(L10n.text("준비한 파일 확인")) {
                ForEach(value.preparedPaths, id: \.self) { pathText($0) }
                if let version = value.cliVersion { Text(version).font(.caption) }
            }
        }
    }

    private func pathText(_ path: String) -> some View {
        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
    }

    private func load() {
        guard !busy else { return }
        busy = true; cancelling = false; error = nil; prepared = nil
        let root = model.projectRoot
        model.startSessionRecovery(using: { await SessionResumeService.list(projectRoot: root, restoredRoot: restoredRoot) }) { result in
            busy = false; cancelling = false
            switch result {
            case .success(let value): inventory = value; selectedID = value.sessions.first?.id ?? ""
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func prepare() {
        guard !busy, let candidate, let workspace, let providerHome else { return }
        busy = true; cancelling = false; error = nil
        let root = model.projectRoot
        model.startSessionRecovery(using: {
            await SessionResumeService.prepare(projectRoot: root, restoredRoot: restoredRoot,
                candidate: candidate, workspace: workspace, providerHome: providerHome)
        }) { result in
            busy = false; cancelling = false
            switch result {
            case .success(let value): prepared = value
            case .failure(let failure):
                error = failure.message + "\n" + L10n.text("지정한 새 앱 환경 폴더에 부분 파일이 남아 있을 수 있습니다. 다시 준비할 때는 새 위치를 선택하세요.")
            }
        }
    }
}

/// SwiftUI owns all selection state; AppKit is used only for native directory
/// panels. No panel or window is retained after its user decision.
@MainActor
enum SessionRecoveryPanels {
    static func directory(title: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
