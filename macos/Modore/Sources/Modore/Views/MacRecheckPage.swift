import AppKit
import SwiftUI

struct MacRecheckPage: View {
    @Environment(\.openURL) private var openURL
    @AppStorage("modore.macRecheck.diagnosticCode") private var diagnosticCode = ""
    @AppStorage("modore.macRecheck.diagnosticNotes") private var diagnosticNotes = ""
    @AppStorage("modore.macRecheck.recordUpdatedAt") private var recordUpdatedAt = 0.0
    @State private var processor = MacRecheckGuide.Processor.current
    @State private var settingsOpenFailed = false
    @State private var guideCopied = false

    let onOpenStorage: () -> Void
    let onOpenActivity: () -> Void
    let onOpenWork: () -> Void

    var body: some View {
        Form {
            backupSection
            diagnosticsSection
            resultSection
            followUpSection
        }
        .macSettingsFormStyle()
        .onChange(of: diagnosticCode) { _ in recordUpdatedAt = Date().timeIntervalSince1970 }
        .onChange(of: diagnosticNotes) { _ in recordUpdatedAt = Date().timeIntervalSince1970 }
        .onChange(of: processor) { _ in guideCopied = false }
    }

    private var backupSection: some View {
        Section {
            actionRow(
                L10n.text("Mac 백업 확인"),
                detail: L10n.text("외장 백업 디스크를 연결하고 Time Machine에서 최근 백업 날짜를 확인하세요.")
            ) {
                Button(L10n.text("Time Machine 열기")) {
                    settingsOpenFailed = false
                    openURL(MacRecheckGuide.timeMachineSettings) { accepted in
                        settingsOpenFailed = !accepted
                    }
                }
                .accessibilityIdentifier("mac-recheck-time-machine")
            }

            VStack(alignment: .leading, spacing: 5) {
                if settingsOpenFailed {
                    Label(L10n.text("설정을 열지 못했습니다. 아래 경로로 직접 이동하세요."), systemImage: "exclamationmark.circle")
                }
                Text(L10n.text("시스템 설정 > 일반 > Time Machine"))
                Text(L10n.text("설정을 연 뒤 백업을 진행하고 완료 시점을 확인하세요."))
                Link(L10n.text("Time Machine 백업 안내"), destination: MacRecheckGuide.backupHelp)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            actionRow(
                L10n.text("AI 세션도 보관하려면"),
                detail: L10n.text("작업 화면에서 세션 원본을 백업할 수 있습니다. 대상은 AI 세션이며 Mac 전체 백업과 별개입니다.")
            ) {
                Button(L10n.text("AI 세션 백업으로 이동"), action: onOpenWork)
                    .accessibilityIdentifier("mac-recheck-session-backup")
            }
        } header: {
            NativeSectionHeader(title: L10n.text("1. 데이터 백업"), subtitle: L10n.text("다시 점검하기 전에 필요한 파일을 보관하세요."))
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Picker(L10n.text("Mac 종류"), selection: $processor) {
                ForEach(MacRecheckGuide.Processor.allCases) { processor in
                    Text(processor.rawValue).tag(processor)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mac-recheck-processor")

            Text(MacRecheckGuide.preparation)
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(processor.instructions.enumerated()), id: \.offset) { index, instruction in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 20, alignment: .trailing)
                        Text(instruction)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("Apple 진단은 Mac을 끈 뒤 버튼과 키로 시작합니다. 종료 전에 안내를 복사해 다른 기기나 메모에 보관하세요."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Button(guideCopied ? L10n.text("안내 복사됨") : L10n.text("안내 복사")) {
                        NSPasteboard.general.clearContents()
                        guideCopied = NSPasteboard.general.setString(
                            MacRecheckGuide.copiedInstructions(for: processor),
                            forType: .string
                        )
                    }
                    .accessibilityIdentifier("mac-recheck-copy-guide")
                    Link(L10n.text("Apple 진단 실행 안내"), destination: MacRecheckGuide.diagnosticsHelp)
                }
            }
        } header: {
            NativeSectionHeader(title: L10n.text("2. Apple 진단 실행"), subtitle: L10n.text("Mac에 내장된 하드웨어 검사로 이어집니다."))
        }
    }

    private var resultSection: some View {
        Section {
            TextField(L10n.text("결과 코드"), text: $diagnosticCode, prompt: Text(L10n.text("예: ADP000")))
                .accessibilityIdentifier("mac-recheck-result-code")
            TextField(L10n.text("메모"), text: $diagnosticNotes, prompt: Text(L10n.text("검사 날짜, 증상, 추가 결과")), axis: .vertical)
                .lineLimit(2...4)
                .accessibilityIdentifier("mac-recheck-result-notes")

            if diagnosticCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "ADP000" {
                Text(L10n.text("ADP000은 이 검사에서 문제를 발견하지 못했다는 뜻이며, 액체 손상 전체를 배제하지는 않습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Link(L10n.text("Apple 결과 코드 해석 보기"), destination: MacRecheckGuide.resultHelp)
                Spacer()
                if recordUpdatedAt > 0 && (!diagnosticCode.isEmpty || !diagnosticNotes.isEmpty) {
                    Text(L10n.format("기록 수정: %@", Date(timeIntervalSince1970: recordUpdatedAt).formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            NativeSectionHeader(title: L10n.text("3. 돌아와서 결과 기록"), subtitle: L10n.text("직접 입력한 내용은 이 Mac에 자동 저장되어 앱을 다시 열어도 남습니다."))
        }
    }

    private var followUpSection: some View {
        Section {
            actionRow(L10n.text("저장공간 확인·정리"), detail: L10n.text("정리할 항목을 검토하고 작업 전후 여유 공간을 비교하세요.")) {
                Button(L10n.text("공간 정리로 이동"), action: onOpenStorage)
                    .accessibilityIdentifier("mac-recheck-storage")
            }
            actionRow(L10n.text("느려짐 다시 확인"), detail: L10n.text("기록 화면에서 CPU·네트워크 관찰을 시작하고 자원을 쓰는 작업을 확인하세요.")) {
                Button(L10n.text("활동 기록으로 이동"), action: onOpenActivity)
                    .accessibilityIdentifier("mac-recheck-activity")
            }
        } header: {
            NativeSectionHeader(title: L10n.text("4. 사용 중 상태 재확인"), subtitle: L10n.text("백업과 진단을 마친 뒤 필요한 작업을 이어가세요."))
        }
    }

    private func actionRow<Action: View>(
        _ title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            action()
                .fixedSize()
        }
    }
}
