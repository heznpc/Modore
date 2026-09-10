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
            Text(source == nil ? L10n.text("백업 확인·복원") : L10n.text("세션 원본 백업"))
                .font(.title2.bold())
            Text(L10n.text("Claude Code·Claude Desktop Code·Codex 세션 원본을 로컬 ZIP으로 보관합니다. 선택한 세션이나 Desktop 대화 단위에 속한 보조 파일도 함께 보존합니다."))
                .font(.callout)
            Text(L10n.text("세션 단위 밖의 작업 폴더와 외부 참조 경로는 따라가지 않습니다. 단위 내부 파일에는 코드·설정 복사본·비밀값이 포함될 수 있습니다. 백업 성공은 원본 삭제 허가가 아닙니다."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let source {
                Text((source as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(3)
                Toggle(L10n.text("원본에 대화·코드·비밀값이 포함될 수 있고, ZIP은 마스킹·암호화되지 않음을 확인했습니다."), isOn: $consent)
                    .font(.callout)
                    .disabled(busy)
                Button(L10n.text("백업 위치 선택…")) { chooseBackupDestination(source: source) }
                    .disabled(!consent || busy)
                    .accessibilityIdentifier("session-backup-create")
            }

            Button(L10n.text("기존 백업 파일 확인…")) { chooseArchive() }
                .disabled(busy)
                .accessibilityIdentifier("session-backup-open")

            if busy {
                ProgressView(L10n.text("파일 복사·SHA-256 검증 중…"))
                    .controlSize(.small)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            if let receipt {
                Divider()
                Label(receipt.status == "restored" ? L10n.text("새 폴더 복원·검증 성공") : L10n.text("백업 파일 검증 성공"),
                      systemImage: "checkmark.shield")
                    .font(.headline)
                Text(receipt.summary).font(.callout)
                Text(L10n.format("포함: %@", String(describing: receipt.includedDescription)))
                    .font(.caption).foregroundStyle(.secondary)
                Text((receipt.archive as NSString).abbreviatingWithTildeInPath)
                    .font(.caption.monospaced()).textSelection(.enabled)
                if let restored = receipt.restoredRoot {
                    Text(L10n.format("복원 위치: %@", String(describing: (restored as NSString).abbreviatingWithTildeInPath)))
                        .font(.caption).textSelection(.enabled)
                }
                Text(L10n.text("파일 무결성을 확인한 결과입니다. Claude·Codex에서 세션 재개가 가능한지까지 보증하지 않습니다. 같은 디스크의 백업은 디스크 고장에 대비한 사본이 아닙니다."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("Finder에서 보기")) {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            URL(fileURLWithPath: receipt.restoredRoot ?? receipt.archive)
                        ])
                    }
                    Button(L10n.text("새 폴더로 복원·검증…")) {
                        chooseRestoreDestination(archive: URL(fileURLWithPath: receipt.archive))
                    }
                    .accessibilityIdentifier("session-backup-restore")
                }
                .disabled(busy)
            }
            HStack {
                Spacer()
                Button(L10n.text("닫기")) { dismiss() }
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
        panel.title = L10n.text("세션 원본 백업 위치")
        panel.message = L10n.text("기존 파일은 덮어쓰지 않습니다. 외장 디스크 등 별도 보관 위치를 선택할 수 있습니다.")
        panel.allowedContentTypes = [.zip]
        let stem = (ScreeService.preserveFilename(tool: tool ?? "session", source: source) as NSString)
            .deletingPathExtension
        panel.nameFieldStringValue = "\(stem)-\(UUID().uuidString.prefix(8)).zip"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.create(source: source, destination: url))
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("Modore 세션 백업 확인")
        panel.allowedContentTypes = [.zip]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.verify(url))
    }

    private func chooseRestoreDestination(archive: URL) {
        let panel = NSSavePanel()
        panel.title = L10n.text("새 복원 폴더 위치")
        panel.message = L10n.text("지정한 이름으로 새 폴더를 만듭니다. 기존 폴더·Claude 저장소를 덮어쓰지 않습니다.")
        panel.nameFieldStringValue = "session-restored-\(UUID().uuidString.prefix(8))"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(.restore(archive: archive, destination: url))
    }

    private func run(_ operation: SessionBackupOperation) {
        busy = true
        error = nil
        receipt = nil
        model.startSessionBackup(operation: operation) { result in
            busy = false
            switch result {
            case .success(let value):
                receipt = value
                AccessibilityAnnouncer.announce(value.status == "restored"
                    ? L10n.text("세션 복원 파일의 무결성을 확인했습니다") : L10n.text("세션 백업 파일의 무결성을 확인했습니다"))
            case .failure(let failure):
                error = failure.message
            }
        }
    }
}
