import SwiftUI

struct BrowserAutomationApprovalSheet: View {
    @EnvironmentObject private var model: ScanModel
    let preview: BrowserAutomationStopPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "memorychip")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("자동화 브라우저 정상 종료")
                        .font(.title3.weight(.semibold))
                    Text("PID와 실행 시작 시각을 실행 직전에 다시 확인합니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("하위 프로세스 포함")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(preview.treeMemoryText)
                        .font(.headline)
                        .monospacedDigit()
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                evidenceRow("프로세스", "PID \(preview.pid) · 부모 \(preview.parentPid)")
                evidenceRow("실행 시간", preview.elapsed.isEmpty ? "확인됨" : preview.elapsed)
                evidenceRow("채널·프로필", "\(channelText) · \(profileText)")
                evidenceRow("메모리", "루트 \(preview.rootMemoryText) · 전체 \(preview.treeMemoryText)")
                evidenceRow("프로세스 수", "루트와 하위 \(preview.processCount)개")
                if !preview.controller.isEmpty {
                    evidenceRow("소유 작업 단서", preview.controller)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("자동화 브라우저 종료 증거")

            Label(
                "일반 Chrome 기본 프로필은 대상에서 제외합니다. SIGTERM 정상 종료만 요청하며, 응답하지 않아도 강제 종료하지 않습니다.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Divider()
            HStack {
                Text("자동 종료 없음 · 사용자 승인 필요")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소", role: .cancel) {
                    model.dismissBrowserAutomationStopPreview()
                }
                .disabled(model.browserAutomationStopInFlight)
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    model.executeBrowserAutomationStop(preview)
                } label: {
                    if model.browserAutomationStopIsExecuting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("정상 종료 요청", systemImage: "stop.circle")
                    }
                }
                .disabled(model.browserAutomationStopInFlight)
                .tint(.red)
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720)
        .interactiveDismissDisabled(model.browserAutomationStopInFlight)
    }

    private var channelText: String {
        preview.channel == "system" ? "시스템 Chrome" : "격리 브라우저"
    }

    private var profileText: String {
        switch preview.profile {
        case "temporary": return "임시 자동화 프로필"
        case "custom": return "사용자 지정 자동화 프로필"
        default: return "격리 기본 프로필"
        }
    }

    private func evidenceRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.callout.weight(.medium))
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
