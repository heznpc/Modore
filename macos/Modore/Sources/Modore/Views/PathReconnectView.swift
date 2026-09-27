import AppKit
import SwiftUI

@MainActor
struct PathReconnectView: View {
    @EnvironmentObject private var model: ScanModel
    @State private var originalPath = ""
    @State private var target: URL?
    @State private var backupSource: String?
    @State private var historyOriginalPath: String?
    @State private var plan: PathReconnectPlan?
    @State private var inventory: PathReconnectInventory?
    @State private var result: PathReconnectConnection?
    @State private var busy = false
    @State private var consent = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                selection
                if let plan { previewContent(plan) }
                if let result {
                    Label(result.statusLabel, systemImage: result.status == "connected" ? "link" : "link.badge.plus")
                        .font(.headline)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                if busy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(L10n.text("경로와 SSD 대상을 확인하고 있습니다…"))
                        Button(L10n.text("중단")) { model.cancelSessionRecovery() }
                    }
                }
                Divider()
                history
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(L10n.text("SSD 경로 재연결"))
        .onAppear { refresh() }
        .onDisappear { if busy { model.cancelSessionRecovery() } }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("SSD 경로 재연결")).font(.title2.bold())
            Text(L10n.text("사라진 로컬 경로에 연결을 만들어, 같은 경로로 SSD의 파일·폴더에 접근합니다."))
            Text(L10n.text("먼저 필요한 자료를 백업에서 SSD의 별도 작업 폴더로 복원하세요. 원래 경로에서 저장·수정하면 연결된 SSD 자료도 바뀌므로, 보존용 백업에는 연결하지 않습니다."))
                .font(.callout).foregroundStyle(.secondary)
            Text(L10n.text("파일 경로 접근만 복구합니다. 앱의 세션 목록·첨부 권한·Git 워크트리 연결은 앱에서 별도로 확인해야 합니다. AI 기록·숨김 자료·앱 관리 폴더는 재연결 대상에서 보호합니다."))
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var selection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.text("사라진 원래 로컬 경로")).font(.headline)
            TextField(L10n.text("파일 또는 폴더의 절대경로"), text: $originalPath)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("path-reconnect-original")
                .onChange(of: originalPath) { value in
                    if value != historyOriginalPath { backupSource = nil; historyOriginalPath = nil }
                    resetPreview()
                }
            if let backupSource {
                Text(L10n.text("정리 기록의 백업 원본 · 작업 사본으로 먼저 복원"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(backupSource).font(.caption.monospaced()).textSelection(.enabled)
            }
            HStack {
                Button(L10n.text("SSD 작업 사본 선택…")) { chooseTarget() }
                    .accessibilityIdentifier("path-reconnect-target")
                Text(target?.path ?? L10n.text("선택하지 않음"))
                    .font(.caption.monospaced()).textSelection(.enabled)
            }
            Button(L10n.text("재연결 미리보기")) { preview() }
                .buttonStyle(.borderedProminent)
                .disabled(originalURL == nil || target == nil)
                .accessibilityIdentifier("path-reconnect-preview")
        }
        .disabled(busy)
    }

    private func previewContent(_ plan: PathReconnectPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("연결할 경로")).font(.headline)
            Text(plan.originalPath).font(.callout.monospaced()).textSelection(.enabled)
            Label(plan.targetPath, systemImage: "arrow.turn.down.right")
                .font(.callout.monospaced()).textSelection(.enabled)
            Text(L10n.message(plan.impact)).font(.callout)
            ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, warning in
                Text(L10n.message(warning)).font(.caption).foregroundStyle(.orange)
            }
            Toggle(L10n.text("보존용 백업이 아닌 작업 사본이며, 기존 경로에서의 변경이 SSD에 저장됨을 확인했습니다."), isOn: $consent)
                .accessibilityIdentifier("path-reconnect-consent")
            Button(L10n.text("원래 경로에 연결 만들기")) { connect() }
                .disabled(!consent)
                .accessibilityIdentifier("path-reconnect-connect")
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .disabled(busy)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("저장된 경로 연결")).font(.headline)
                Spacer()
                Button(L10n.text("연결 상태 새로 확인")) { refresh() }
                    .disabled(busy).accessibilityIdentifier("path-reconnect-refresh")
            }
            if let inventory {
                ForEach(Array(inventory.warnings.enumerated()), id: \.offset) { _, warning in
                    Text(L10n.message(warning)).font(.caption).foregroundStyle(.orange)
                }
                if inventory.connections.isEmpty {
                    Text(L10n.text("아직 만든 경로 연결이 없습니다.")).foregroundStyle(.secondary)
                }
                ForEach(inventory.connections) { connection in connectionRow(connection) }
                if !inventory.candidates.isEmpty {
                    DisclosureGroup(L10n.format("정리 기록에서 원래 경로 선택 · %@개", String(inventory.candidates.count))) {
                        Text(L10n.text("삭제 기록은 경로 선택에만 사용합니다. 백업 사본의 현재 상태나 앱 연결 가능 여부를 증명하지 않습니다."))
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 5)
                        ForEach(inventory.candidates) { candidate in
                            HStack(alignment: .top) {
                                Text(candidate.originalPath).font(.caption.monospaced()).textSelection(.enabled)
                                Spacer()
                                Button(L10n.text("이 원래 경로 사용")) {
                                    originalPath = candidate.originalPath
                                    historyOriginalPath = candidate.originalPath
                                    backupSource = candidate.targetPath
                                    target = nil
                                    resetPreview()
                                }.disabled(busy)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
        }
    }

    private func connectionRow(_ connection: PathReconnectConnection) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(connection.statusLabel).fontWeight(.medium)
                Spacer()
                Button(L10n.text("연결만 해제")) { disconnect(connection) }
                    .disabled(busy || !connection.canDisconnect)
            }
            Text(connection.originalPath).font(.caption.monospaced()).textSelection(.enabled)
            Label(connection.targetPath, systemImage: "arrow.turn.down.right").font(.caption.monospaced()).textSelection(.enabled)
            if !connection.reason.isEmpty {
                Text(L10n.message(connection.reason)).font(.caption).foregroundStyle(.secondary)
            }
            Text(L10n.text("연결 해제는 로컬 연결만 제거하며 SSD 파일은 유지합니다."))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var originalURL: URL? {
        let path = (originalPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/"), path != "/", !path.contains("\0") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func chooseTarget() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("SSD 작업 사본 선택")
        panel.message = L10n.text("보존용 백업 밖에 복원한 파일 또는 폴더를 선택하세요. 이 자료는 앱이 수정할 수 있습니다.")
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            target = url.standardizedFileURL
            resetPreview()
        }
    }

    private func resetPreview() { plan = nil; result = nil; consent = false; error = nil }

    private func refresh() {
        guard !busy else { return }
        busy = true; error = nil
        let root = model.projectRoot
        model.startSessionRecovery(using: { await PathReconnectService.inventory(projectRoot: root) }) { response in
            busy = false
            switch response {
            case .success(let value): inventory = value
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func preview() {
        guard let original = originalURL, let target else { return }
        resetPreview(); busy = true
        let root = model.projectRoot
        model.startSessionRecovery(using: { await PathReconnectService.preview(projectRoot: root, original: original, target: target) }) { response in
            busy = false
            switch response {
            case .success(let value): plan = value
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func connect() {
        guard let plan, consent else { return }
        busy = true; error = nil
        let root = model.projectRoot
        model.startSessionRecovery(using: { await PathReconnectService.connect(projectRoot: root, plan: plan) }) { response in
            busy = false; consent = false
            switch response {
            case .success(let value):
                result = value; self.plan = nil; refresh()
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func disconnect(_ connection: PathReconnectConnection) {
        busy = true; error = nil
        let root = model.projectRoot
        model.startSessionRecovery(using: { await PathReconnectService.disconnect(projectRoot: root, connection: connection) }) { response in
            busy = false
            switch response {
            case .success(let value): result = value; refresh()
            case .failure(let failure): error = failure.message
            }
        }
    }
}
