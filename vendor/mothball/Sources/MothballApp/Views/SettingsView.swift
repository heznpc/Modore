import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("아카이브") {
                LabeledContent("저장 위치") {
                    HStack(spacing: 8) {
                        Text(model.archiveDirectory.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(model.archiveDirectory.path)
                        Button("변경...") { pickArchiveDirectory() }
                    }
                }
            }

            Section("스캔") {
                Toggle("아카이브 전에 git fetch 실행", isOn: $model.fetchBeforeArchive)
                Text("origin과 동기화하여 push 상태를 정확히 확인합니다. 스캔이 느려지고 네트워크 트래픽이 발생합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 240)
    }

    private func pickArchiveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "아카이브 저장 위치를 선택하세요"
        if panel.runModal() == .OK, let url = panel.url {
            model.archiveDirectory = url
        }
    }
}
