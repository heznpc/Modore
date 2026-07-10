import AppKit
import Foundation
import SwiftUI

@main
struct PCHealthCheckMacApp: App {
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
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 1020, minHeight: 700)
        }
        .windowStyle(.titleBar)
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

struct CleanupApprovalSheet: View {
    @EnvironmentObject private var model: ScanModel
    let preview: CleanupPreview

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: preview.canExecute ? "trash.circle.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(preview.label)
                        .font(.title2.bold())
                    Text(preview.statusText)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("현재 논리 크기")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(preview.estimatedText)
                        .font(.title3.bold())
                        .monospacedDigit()
                }
            }

            if let sizeChangeNotice {
                Label(sizeChangeNotice, systemImage: "clock.arrow.circlepath")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !preview.blockedReason.isEmpty {
                Label(preview.blockedReason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if !preview.runningProcesses.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("감지된 실행 항목")
                        .font(.headline)
                    ForEach(Array(runningProcesses.enumerated()), id: \.offset) { _, process in
                        Label(process.name, systemImage: "app")
                            .font(.callout)
                            .lineLimit(1)
                            .help(process.rawCommand)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("정리 대상")
                    .font(.headline)
                ForEach(preview.targets, id: \.self) { target in
                    Text(target)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
            }

            if !preview.warning.isEmpty {
                Text(preview.warning)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Divider()
            HStack {
                Label("AI 호출 없음 · 고정된 로컬 레시피", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("취소") {
                    model.dismissCleanupPreview()
                }
                .disabled(model.cleanupInFlight)
                if preview.status == "blocked" {
                    Button {
                        model.retryCleanupPreview(preview)
                    } label: {
                        if model.cleanupInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("다시 확인", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(model.cleanupInFlight)
                    .keyboardShortcut(.defaultAction)
                }
                if preview.canExecute {
                    Button(role: .destructive) {
                        model.executeCleanup(preview)
                    } label: {
                        if model.cleanupInFlight {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(executeLabel, systemImage: "trash")
                        }
                    }
                    .disabled(model.cleanupInFlight)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 560, idealWidth: 620, minHeight: 340)
        .interactiveDismissDisabled(model.cleanupInFlight)
    }

    private var statusColor: Color {
        switch preview.status {
        case "ready": return .orange
        case "complete": return .green
        case "empty": return .secondary
        default: return .red
        }
    }

    private var executeLabel: String {
        switch preview.actionMode {
        case "trash": return "휴지통으로 이동"
        case "simulator": return "Simulator 삭제"
        default: return "정리 실행"
        }
    }

    private var sizeChangeNotice: String? {
        let item = model.storage?.cleanupCandidates.first(where: {
            $0.cleanupID == preview.recipeID
        })
        return CleanupPresentation.sizeChangeNotice(
            snapshotAge: model.storageSnapshotAgeText,
            scannedSize: item?.sizeText,
            previewSize: preview.estimatedText
        )
    }

    private var runningProcesses: [CleanupProcessDisplay] {
        CleanupPresentation.processDisplays(from: preview.runningProcesses)
    }
}
