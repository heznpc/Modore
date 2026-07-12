import AppKit
import Foundation
import SwiftUI

@MainActor
final class PCHealthCheckApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var model: ScanModel?
    private var terminationReplyPending = false

    func bind(to model: ScanModel) {
        self.model = model
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        guard let model else { return .terminateNow }

        let deferred = model.deferApplicationTerminationUntilSafe { [weak self] in
            guard let self, self.terminationReplyPending else { return }
            self.terminationReplyPending = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        guard deferred else { return .terminateNow }
        terminationReplyPending = true
        return .terminateLater
    }
}

@main
struct PCHealthCheckMacApp: App {
    @NSApplicationDelegateAdaptor(PCHealthCheckApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var model = ScanModel()

    init() {
        switch ProcessInfo.processInfo.environment["PCH_FORCE_APPEARANCE"]?.lowercased() {
        case "light":
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        default:
            break
        }
    }

    var body: some Scene {
        Window("PC Health Check Mac", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear {
                    applicationDelegate.bind(to: model)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRunning ? "검사 취소" : "지금 검사") {
                    if model.isRunning {
                        model.cancelScan()
                    } else {
                        model.runScan()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.cleanupInFlight || (model.isBusy && !model.isRunning))

                Divider()

                Button("일반 리포트 열기") {
                    model.openNormalReportInBrowser()
                }
                .disabled(!model.hasNormalReport)

                Button("공유용 리포트 열기") {
                    model.openShareReportInBrowser()
                }
                .disabled(!model.hasShareReport)

                Button("리포트를 Finder에서 보기") {
                    model.revealReportsInFinder()
                }
                .disabled(!model.hasAnyReport)
            }
        }

        Settings {
            StorageWatchSettingsView()
                .environmentObject(model)
        }
    }
}

struct StorageWatchSettingsView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            Section("저장공간 급감 감시") {
                Toggle(
                    "매시간 여유 공간 확인",
                    isOn: Binding(
                        get: { model.storageWatchEnabled },
                        set: { model.setStorageWatchEnabled($0) }
                    )
                )
                .disabled(model.storageWatchInFlight || model.isRunning || model.cleanupInFlight)

                Text("20GB 미만이거나 한 시간에 8GB 이상 줄면 알림을 보냅니다. 급감 시에는 원인 복원을 위해 알려진 캐시·개발 경로를 최대 8개, 총 8초 안에서 측정합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.storageWatchInFlight {
                    ProgressView("설정 적용 중")
                        .controlSize(.small)
                } else {
                    Text(model.storageWatchDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("개인정보") {
                Label("기록은 이 Mac 안에만 저장합니다.", systemImage: "lock.shield")
                Text("평소에는 여유 공간과 검사 시각만 기록합니다. 8GB 이상 급감할 때만 고정된 후보 경로·크기·측정 상태를 남기며, 파일 내용은 읽거나 기록하지 않고 자동 삭제도 실행하지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 330)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        ModernRootView()
        .sheet(item: $model.cleanupPreview) { preview in
            CleanupApprovalSheet(preview: preview)
                .environmentObject(model)
        }
    }
}
