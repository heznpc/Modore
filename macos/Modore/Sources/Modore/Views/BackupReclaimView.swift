import AppKit
import SwiftUI

@MainActor
struct BackupReclaimView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var local: URL?
    @State private var backup: URL?
    @State private var plan: BackupReclaimPlan?
    @State private var receipt: BackupReclaimReceipt?
    @State private var selected: Set<String> = []
    @State private var busy = false
    @State private var consent = false
    @State private var confirming = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("백업 중복 정리")).font(.title2.bold())
            Text(L10n.text("SSD와 같은 파일을 확인하고, 계속 쓸 자료를 보호하며 로컬 사본을 정리합니다."))
                .foregroundStyle(.secondary)
            Text(L10n.text("Codex·Claude 대화 JSONL, 앱 상태·설정, 숨김 자료, Git 작업 폴더는 보호합니다. 일반 파일도 삭제하면 기존 로컬 경로에서 열 수 없습니다."))
                .font(.callout)
            folderPicker
            if let plan {
                Text(L10n.format("비교한 항목 %@개 · 내용과 복원 속성이 같은 파일 %@", String(plan.rows.count), size(plan.identicalBytes)))
                    .font(.headline)
                Text(L10n.message(plan.coverage)).font(.caption).foregroundStyle(.secondary)
                if !plan.complete {
                    Label(L10n.text("일부 범위만 비교했습니다. 나머지는 더 작은 폴더로 나누어 확인하세요."), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(L10n.message(warning)).font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Button(L10n.text("선택 가능 항목 선택")) {
                        selected = Set(plan.rows.filter(\.selectable).prefix(1_000).map(\.id))
                        consent = false
                    }.disabled(busy || receipt != nil)
                    Button(L10n.text("선택 해제")) { selected.removeAll(); consent = false }.disabled(busy)
                    Spacer()
                    Text(L10n.format("선택 %@개 · %@", String(selected.count), size(selectedBytes)))
                }
                List(plan.rows) { row in
                    HStack(alignment: .top) {
                        Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: {
                            if $0 && selected.count < 1_000 { selected.insert(row.id) } else { selected.remove(row.id) }
                            consent = false
                        })) { Text(row.path).textSelection(.enabled) }
                        .disabled(!row.selectable || busy || receipt != nil)
                        .accessibilityIdentifier("backup-reclaim-row-" + row.id)
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text(row.statusLabel).fontWeight(.medium)
                            if let bytes = row.bytes { Text(size(bytes)).monospacedDigit() }
                            Text(L10n.message(row.reason)).font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: 420, alignment: .trailing)
                        }
                    }.padding(.vertical, 5)
                }.frame(minHeight: 180)
                if receipt == nil {
                    Toggle(L10n.text("선택한 파일의 로컬 경로가 사라지고, 복구에는 SSD 사본이 필요함을 확인했습니다."), isOn: $consent)
                        .disabled(busy || selected.isEmpty)
                        .accessibilityIdentifier("backup-reclaim-consent")
                    HStack {
                        Text(L10n.text("파일 크기는 실제 확보량이 아닙니다. 실행 후 디스크 여유 공간을 별도로 측정합니다."))
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("선택한 로컬 파일 삭제…"), role: .destructive) { confirming = true }
                            .disabled(busy || !consent || selected.isEmpty)
                            .accessibilityIdentifier("backup-reclaim-delete")
                    }
                }
            } else { Spacer() }
            if let receipt { receiptContent(receipt) }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("파일 내용과 사용 상태를 확인하고 있습니다…")).font(.callout)
                    Button(L10n.text("중단")) { model.cancelSessionRecovery() }
                }
                Spacer()
                Button(L10n.text("정리 기록 폴더 열기")) {
                    NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Library/Application Support/Modore/backup-reclaim"))
                }
            }
        }
        .padding(20)
        .navigationTitle(L10n.text("백업 중복 정리"))
        .onDisappear { if busy { model.cancelSessionRecovery() } }
        .confirmationDialog(L10n.text("선택한 로컬 파일을 영구 삭제할까요?"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L10n.text("다시 검증 후 로컬 파일 삭제"), role: .destructive) { deleteSelected() }
            Button(L10n.text("취소"), role: .cancel) {}
        } message: {
            Text(L10n.format("%@개 · %@. SSD 사본을 다시 읽어 비교합니다. 바뀌었거나 사용 중인 파일은 건너뛰며, SSD 파일은 유지합니다.", String(selected.count), size(selectedBytes)))
        }
    }

    private var folderPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(L10n.text("로컬 폴더 선택…")) {
                    if let folder = SessionRecoveryPanels.directory(title: L10n.text("정리할 로컬 폴더"), message: L10n.text("다운로드·문서 등 직접 관리하는 폴더를 선택하세요.")) {
                        local = folder.resolvingSymlinksInPath(); reset()
                    }
                }.accessibilityIdentifier("backup-reclaim-local")
                Text(local?.path ?? L10n.text("선택하지 않음")).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("대응하는 SSD 폴더 선택…")) {
                    if let folder = SessionRecoveryPanels.directory(title: L10n.text("대응하는 SSD 백업 폴더"), message: L10n.text("로컬 폴더와 같은 파일 구조의 백업 폴더를 선택하세요. 예: 로컬 Downloads ↔ 백업의 home/사용자/Downloads")) {
                        backup = folder.resolvingSymlinksInPath(); reset()
                    }
                }.accessibilityIdentifier("backup-reclaim-backup")
                Text(backup?.path ?? L10n.text("선택하지 않음")).font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(L10n.text("양쪽 파일 비교")) { compare() }
                .buttonStyle(.borderedProminent).disabled(local == nil || backup == nil)
                .accessibilityIdentifier("backup-reclaim-compare")
        }.disabled(busy)
    }

    private func receiptContent(_ receipt: BackupReclaimReceipt) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.format("삭제 %@개 · 건너뜀 %@개 · 삭제한 파일 크기 %@",
                String(receipt.items.filter { $0.status == "deleted" }.count),
                String(receipt.items.filter { $0.status == "blocked" }.count), size(receipt.deletedBytes))).font(.headline)
            if let after = receipt.freeBytesAfter {
                Text(L10n.format("디스크 여유 공간: %@ → %@", size(receipt.freeBytesBefore), size(after)))
            }
            Text(receipt.receiptPath).font(.caption.monospaced()).textSelection(.enabled)
            ForEach(receipt.items.filter { $0.status == "blocked" }.prefix(5)) { item in
                Text(item.path + ": " + L10n.message(item.reason ?? "")).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var selectedBytes: Int64 { plan?.rows.filter { selected.contains($0.id) }.reduce(0) { $0 + ($1.bytes ?? 0) } ?? 0 }
    private func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    private func reset() { plan = nil; receipt = nil; selected = []; consent = false; error = nil }

    private func compare() {
        guard let local, let backup else { return }
        reset(); busy = true
        let root = model.projectRoot
        model.startSessionRecovery(using: { await BackupReclaimService.compare(projectRoot: root, local: local, backup: backup) }) { result in
            busy = false
            switch result {
            case .success(let value): plan = value
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func deleteSelected() {
        guard let plan, consent, !selected.isEmpty else { return }
        busy = true; error = nil
        let root = model.projectRoot, ids = selected
        model.startSessionRecovery(using: { await BackupReclaimService.delete(projectRoot: root, plan: plan, selected: ids) }) { result in
            busy = false; consent = false
            switch result {
            case .success(let value): receipt = value
            case .failure(let failure): error = failure.message
            }
        }
    }
}
