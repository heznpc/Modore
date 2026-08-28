import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Explicit raw-data operations only. This sheet never changes a retirement
/// verdict, deletes a source, or restores over a live provider store.
@MainActor
struct SessionBackupSheet: View {
    @EnvironmentObject private var model: ScanModel
    @Environment(\.dismiss) private var dismiss
    let source: String?
    let tool: String?

    @State private var consent = false
    @State private var busy = false
    @State private var receipt: SessionBackupReceipt?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(source == nil ? "백업 확인·복원" : "세션 원본 백업")
                .font(.title2.bold())
            Text("Claude·Codex 세션 원본을 로컬 ZIP으로 보관합니다. Claude는 해당 세션의 서브에이전트·도구 결과·파일 스냅샷·이미지·첨부 파일도 있는 만큼 포함합니다.")
                .font(.callout)
            Text("작업 폴더의 코드, 프로젝트 메모리, 설정·인증정보 파일과 외부 경로의 파일은 포함하지 않습니다. 백업 성공은 원본 삭제 허가가 아닙니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let source {
                Text((source as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Toggle("원본에 대화·코드·비밀값이 포함될 수 있고, ZIP은 마스킹·암호화되지 않음을 확인했습니다.", isOn: $consent)
                    .font(.callout)
                    .disabled(busy)
                Button("백업 위치 선택…") { chooseBackupDestination(source: source) }
                    .disabled(!consent || busy)
                    .accessibilityIdentifier("session-backup-create")
            }

            Button("기존 백업 파일 확인…") { chooseArchive() }
                .disabled(busy)
                .accessibilityIdentifier("session-backup-open")

            if busy {
                ProgressView("파일 복사·SHA-256 검증 중…")
                    .controlSize(.small)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let receipt {
                Divider()
                Label(receipt.status == "restored" ? "새 폴더 복원·검증 성공" : "백업 파일 검증 성공",
                      systemImage: "checkmark.shield")
                    .font(.headline)
                Text(receipt.summary).font(.callout)
                Text("포함: \(receipt.includedDescription)")
                    .font(.caption).foregroundStyle(.secondary)
                Text((receipt.archive as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).textSelection(.enabled)
                if let restored = receipt.restoredRoot {
                    Text("복원 위치: \((restored as NSString).abbreviatingWithTildeInPath)")
                        .font(.caption).textSelection(.enabled)
                }
                Text("파일 무결성을 확인한 결과입니다. Claude·Codex에서 세션 재개가 가능한지까지 보증하지 않습니다. 같은 디스크의 백업은 디스크 고장에 대비한 사본이 아닙니다.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Finder에서 보기") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: receipt.restoredRoot ?? receipt.archive)
                        ])
                    }
                    Button("새 폴더로 복원·검증…") {
                        chooseRestoreDestination(archive: URL(fileURLWithPath: receipt.archive))
                    }
                    .accessibilityIdentifier("session-backup-restore")
                }
                .disabled(busy)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(busy)
    }

    private func chooseBackupDestination(source: String) {
        let panel = NSSavePanel()
        panel.title = "세션 원본 백업 위치"
        panel.message = "기존 파일은 덮어쓰지 않습니다. 외장 디스크 등 별도 보관 위치를 선택할 수 있습니다."
        panel.allowedContentTypes = [.zip]
        let stem = (ScreeService.preserveFilename(tool: tool ?? "session", source: source) as NSString)
            .deletingPathExtension
        panel.nameFieldStringValue = "\(stem)-\(UUID().uuidString.prefix(8)).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.create(source: source, destination: url))
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = "Modore 세션 백업 확인"
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.verify(url))
    }

    private func chooseRestoreDestination(archive: URL) {
        let panel = NSSavePanel()
        panel.title = "새 복원 폴더 위치"
        panel.message = "지정한 이름으로 새 폴더를 만듭니다. 기존 폴더·Claude 저장소를 덮어쓰지 않습니다."
        panel.nameFieldStringValue = "session-restored-\(UUID().uuidString.prefix(8))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.restore(archive: archive, destination: url))
    }

    private func run(_ operation: SessionBackupOperation) {
        busy = true
        error = nil
        receipt = nil
        Task {
            let result = await ScreeService.sessionBackup(projectRoot: model.projectRoot, operation: operation)
            busy = false
            switch result {
            case .success(let value):
                receipt = value
                AccessibilityAnnouncer.announce(value.status == "restored"
                    ? "세션 복원 파일의 무결성을 확인했습니다" : "세션 백업 파일의 무결성을 확인했습니다")
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}
