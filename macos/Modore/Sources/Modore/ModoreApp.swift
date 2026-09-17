import AppKit
import Darwin
import Foundation
import SwiftUI

@MainActor
final class PCHealthCheckApplicationDelegate: NSObject, NSApplicationDelegate {
    private weak var model: ScanModel?
    private var terminationReplyPending = false
    private var pendingTerminationConditions = 0

    func bind(to model: ScanModel) {
        self.model = model
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateLater }
        guard let model else { return .terminateNow }

        var deferredConditions = 0
        if model.cancelApplicationTasksForTermination(completion: { [weak self] in
            self?.finishTerminationCondition(sender: sender)
        }) {
            deferredConditions += 1
        }
        if model.deferApplicationTerminationUntilSafe({ [weak self] in
            self?.finishTerminationCondition(sender: sender)
        }) {
            deferredConditions += 1
        }
        guard deferredConditions > 0 else { return .terminateNow }
        pendingTerminationConditions = deferredConditions
        terminationReplyPending = true
        return .terminateLater
    }

    private func finishTerminationCondition(sender: NSApplication) {
        guard terminationReplyPending, pendingTerminationConditions > 0 else { return }
        pendingTerminationConditions -= 1
        guard pendingTerminationConditions == 0 else { return }
        terminationReplyPending = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}

@main
struct ModoreApp: App {
    @NSApplicationDelegateAdaptor(PCHealthCheckApplicationDelegate.self)
    private var applicationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var maintenance = QuietMaintenanceService()
    @StateObject private var cpuWatch = CPUWatchService()
    @StateObject private var quotaWork = QuotaWorkModel()
    @StateObject private var ciWatch = CIWatchService()
    @StateObject private var model: ScanModel
    /// Retaining the descriptor is what retains singleton ownership. The lock
    /// is released automatically after normal or deferred app termination.
    private let instanceLease: AppInstanceCoordinator.Lease?

    init() {
        if let request = BackgroundNotifier.pendingRequest(in: CommandLine.arguments) {
            BackgroundNotifier.postAndExit(request: request)
        }
        switch AppInstanceCoordinator.acquire() {
        case .continueRunning(let lease, let obsoletePeers):
            instanceLease = lease
            // A source-built copy and an installed copy share one app
            // identity. Ask older peers to terminate normally; their delegate
            // defers while a destructive transaction is in flight.
            for peer in obsoletePeers {
                peer.terminate()
            }
        case .activateExistingAndExit(let existing):
            existing?.activate(options: [.activateAllWindows])
            Darwin.exit(EXIT_SUCCESS)
        case .cannotCoordinate:
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("Modore를 안전하게 시작할 수 없습니다")
            alert.informativeText = L10n.text("단일 실행 잠금 파일을 안전하게 열 수 없습니다. ~/Library/Application Support/Modore의 소유권과 심볼릭 링크 상태를 확인하세요.")
            alert.runModal()
            Darwin.exit(EXIT_FAILURE)
        }
        _model = StateObject(wrappedValue: ScanModel())
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
        Window("Modore", id: "main") {
            ContentView()
                .environment(\.layoutDirection, .leftToRight)
                .environmentObject(cpuWatch)
                .environmentObject(quotaWork)
                .environmentObject(ciWatch)
                .environmentObject(model)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear {
                    cpuWatch.start()
                    maintenance.start(model: model)
                    ciWatch.start(model: model)
                    applicationDelegate.bind(to: model)
                    model.setApplicationActive(scenePhase == .active)
                }
                .onChange(of: scenePhase) { phase in
                    model.setApplicationActive(phase == .active)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 760)
        .handlesExternalEvents(matching: ["*"])
        .commands {
            CommandGroup(after: .newItem) {
                Button(model.isRunning ? L10n.text("정밀 검사 취소") : L10n.text("정밀 검사")) {
                    if model.isRunning {
                        model.cancelScan()
                    } else {
                        model.runScan()
                    }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.cleanupInFlight || (model.isBusy && !model.isRunning))

                Divider()

                Button(L10n.text("일반 리포트 열기")) {
                    model.openNormalReportInBrowser()
                }
                .disabled(!model.hasNormalReport)

                Button(L10n.text("공유용 리포트 열기")) {
                    model.openShareReportInBrowser()
                }
                .disabled(!model.hasShareReport)

                Button(L10n.text("리포트를 Finder에서 보기")) {
                    model.revealReportsInFinder()
                }
                .disabled(!model.hasAnyReport)
            }
        }

        Settings {
            StorageWatchSettingsView()
                .environmentObject(cpuWatch)
                .environmentObject(quotaWork)
                .environmentObject(model)
        }
    }
}

struct StorageWatchSettingsView: View {
    @EnvironmentObject private var cpuWatch: CPUWatchService
    @AppStorage("automaticDeepScan") private var automaticDeepScan = false
    @EnvironmentObject private var model: ScanModel

    var body: some View {
        Form {
            Section(L10n.text("저장공간 급감 감시")) {
                Toggle(
                    L10n.text("앱 종료 후에도 매분 여유 공간 확인"),
                    isOn: Binding(
                        get: { model.storageWatchEnabled },
                        set: { model.setStorageWatchEnabled($0) }
                    )
                )
                .disabled(model.storageWatchInFlight || model.isRunning || model.cleanupInFlight)

                Text(L10n.text("20·10·5·3GB 아래로 내려가면 알립니다. 5GB 미만은 10분, 3GB 미만은 5분마다 다시 알리며, 한 시간에 8GB 이상 줄어도 경고합니다. 알림에서 공간 확보와 실행 중인 앱 확인을 열 수 있습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if model.storageWatchInFlight {
                    ProgressView(L10n.text("설정 적용 중"))
                        .controlSize(.small)
                } else {
                    Text(model.storageWatchDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.text("Mac 상태 감시")) {
                Toggle(L10n.text("공간·RAM·스왑·CPU 감시와 알림"), isOn: Binding(
                    get: { cpuWatch.enabled }, set: { value in Task { await cpuWatch.setEnabled(value) } }
                ))
                .disabled(cpuWatch.configuring)
                Text(L10n.text("Modore 실행 중 약 2초마다 공간·RAM·CPU를 관찰하고, 공간이 부족하면 Dock에도 잔여 용량을 표시합니다. 앱 종료 후 공간 감시는 위의 매분 확인 설정을 따릅니다. RAM 압박이나 지속 CPU 부하는 10분마다, 위험한 RAM 압박은 5분마다 다시 알립니다."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(L10n.text("기준: 전체 코어 평균 70% 이상, 프로세스 하나가 150% 이상, 또는 macOS 열압력과 CPU 부하가 함께 감지될 때. CPU 100%는 코어 1개입니다."))
                    .font(.caption).foregroundStyle(.secondary)
                Text(cpuWatch.detail).font(.caption).textSelection(.enabled)
                Text(cpuWatch.notificationStatus).font(.caption).textSelection(.enabled)
                Button(L10n.text("테스트 알림 보내기")) { Task { await cpuWatch.sendTestNotification() } }
                    .disabled(!cpuWatch.enabled || cpuWatch.configuring)
            }

            Section(L10n.text("정밀 검사")) {
                Toggle(L10n.text("오래된 정밀 검사 결과 자동 갱신"), isOn: $automaticDeepScan)
                Text(L10n.text("기본은 수동 검사입니다. 실시간 여유 공간 표시는 정밀 검사 없이 계속 갱신됩니다."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L10n.text("개인정보")) {
                Label(L10n.text("기록은 이 Mac 안에만 저장합니다."), systemImage: "lock.shield")
                Text(L10n.text("Mac 상태 감시는 공간·스왑·RAM 압박·CPU 상위 프로세스와 작업 경로를 이 Mac에 최대 40건 기록합니다. 매분 공간 감시는 시각·여유 공간을 기록하고, 용량 부족이나 급감 시 알려진 경로의 크기와 실행 상태를 제한된 시간 안에 측정합니다. 대화·파일 내용 수집과 자동 삭제는 하지 않습니다."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 700)
        .task {
            while !Task.isCancelled {
                await model.refreshStorageWatchStatus()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) }
                catch { return }
            }
        }
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
        .sheet(item: $model.cleanupRecoveryPlan) { plan in
            CleanupRecoverySheet(initialPlan: plan)
                .environmentObject(model)
        }
        .sheet(item: $model.browserAutomationStopPreview) { preview in
            BrowserAutomationApprovalSheet(preview: preview)
                .environmentObject(model)
        }
    }
}
