import AppKit
import Foundation

extension ScanModel {
    func showNormalReport() {
        guard hasNormalReport else { return }
        selectedReportURL = normalReportURL
        selectedReportTitle = "일반 리포트"
        reportRevision += 1
    }

    func showShareReport() {
        guard hasShareReport else { return }
        selectedReportURL = shareReportURL
        selectedReportTitle = "공유용 리포트"
        reportRevision += 1
    }

    func openNormalReportInBrowser() {
        guard hasNormalReport else { return }
        selectedReportURL = normalReportURL
        selectedReportTitle = "일반 리포트"
        NSWorkspace.shared.open(normalReportURL)
    }

    func openShareReportInBrowser() {
        guard hasShareReport else { return }
        selectedReportURL = shareReportURL
        selectedReportTitle = "공유용 리포트"
        NSWorkspace.shared.open(shareReportURL)
    }

    func openCurrentReportInBrowser() {
        guard let url = selectedReportURL else { return }
        NSWorkspace.shared.open(url)
    }

    func revealReportsInFinder() {
        let target = selectedReportURL ?? (hasNormalReport ? normalReportURL : projectRoot)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([projectRoot.appendingPathComponent("data/config.json")])
    }

    func openFullDiskAccessSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles"
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    func revealStorageItem(_ item: StorageItem) {
        let url = URL(fileURLWithPath: item.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            errorMessage = "경로를 찾을 수 없어 클립보드에 복사했습니다: \(item.path)"
            copyToPasteboard(item.path)
        }
    }

    func copyGuide(for item: StorageItem) {
        copyToPasteboard(cleanupGuide(for: item))
    }

    func prepareCleanup(_ item: StorageItem) {
        guard item.canCleanup else { return }
        prepareCleanup(recipeID: item.cleanupID, label: item.label)
    }

    func prepareCleanup(_ device: SimulatorDevice) {
        guard !isSimulatorProtected(device), !device.cleanupID.isEmpty else { return }
        prepareCleanup(recipeID: device.cleanupID, label: device.name)
    }

    func isSimulatorProtected(_ device: SimulatorDevice) -> Bool {
        device.isBooted || simulatorKeepNames.contains(device.name)
    }

    func toggleSimulatorProtection(_ device: SimulatorDevice) {
        guard !device.isBooted else { return }
        var updatedNames = simulatorKeepNames
        let isRemoving = updatedNames.contains(device.name)
        if isRemoving {
            updatedNames.remove(device.name)
        } else {
            updatedNames.insert(device.name)
        }
        do {
            try Self.saveSimulatorKeepNames(updatedNames)
            replaceSimulatorKeepNames(with: updatedNames)
            appendLog(isRemoving ? "Simulator 보존 해제: \(device.name)" : "Simulator 보존: \(device.name)")
        } catch {
            errorMessage = "Simulator 보존 목록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func prepareCleanup(recipeID: String, label: String) {
        guard !recipeID.isEmpty, !isBusy else { return }
        cleanupInFlight = true
        errorMessage = nil
        appendLog("정리 미리보기: \(label)")
        let root = projectRoot
        Task {
            let result = await LocalProcessRunner.capture(
                executable: "/bin/bash",
                arguments: ["./scripts/cleanup.sh", "--preview", recipeID],
                currentDirectory: root
            )
            cleanupInFlight = false
            guard let preview = CleanupPreview(protocolText: result.output) else {
                errorMessage = "정리 미리보기 결과를 읽지 못했습니다. 실행 로그를 확인하세요."
                appendLog("정리 미리보기 실패: \(result.status)")
                return
            }
            cleanupPreview = preview
            appendLog("미리보기: \(preview.statusText), 논리 크기 \(preview.estimatedText)")
        }
    }

    func executeCleanup(_ preview: CleanupPreview) {
        guard preview.canExecute, !isBusy, cleanupPreview?.recipeID == preview.recipeID else { return }
        cleanupInFlight = true
        errorMessage = nil
        appendLog("승인형 정리 실행: \(preview.label)")
        let root = projectRoot
        Task {
            let result = await LocalProcessRunner.capture(
                executable: "/bin/bash",
                arguments: ["./scripts/cleanup.sh", "--execute", preview.recipeID, "--owner-approved"],
                currentDirectory: root
            )
            guard let executed = CleanupPreview(protocolText: result.output) else {
                cleanupInFlight = false
                errorMessage = "정리 실행 결과를 읽지 못했습니다. 사용자 파일 정리는 다시 실행하지 말고 로그를 확인하세요."
                appendLog("정리 실행 결과 해석 실패: \(result.status)")
                return
            }
            if result.status == 0 && executed.isComplete {
                if executed.actionMode == "trash" {
                    appendLog("휴지통 이동 완료: \(executed.reclaimedText). 휴지통을 비운 뒤 실제 공간이 회수됩니다.")
                } else {
                    appendLog("정리 완료: 논리 크기 \(executed.reclaimedText), 실제 여유 변화 \(executed.physicalDeltaText)")
                }
                if !executed.receipt.isEmpty {
                    appendLog("영수증: \(executed.receipt)")
                }
                cleanupPreview = nil
                state = .running
                let ok = await ScanPipeline.run(projectRoot: root) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
                cleanupInFlight = false
                finishRun(success: ok)
            } else {
                cleanupInFlight = false
                cleanupPreview = executed
                errorMessage = executed.blockedReason.isEmpty
                    ? "일부 항목을 정리하지 못했습니다. 영수증과 실행 로그를 확인하세요."
                    : executed.blockedReason
                appendLog("정리 중단: \(executed.statusText)")
            }
        }
    }

    func retryCleanupPreview(_ preview: CleanupPreview) {
        guard !isBusy, cleanupPreview?.recipeID == preview.recipeID else { return }
        prepareCleanup(recipeID: preview.recipeID, label: preview.label)
    }

    func dismissCleanupPreview() {
        guard !cleanupInFlight else { return }
        cleanupPreview = nil
    }

    func setStorageWatchEnabled(_ enabled: Bool) {
        guard !storageWatchInFlight, enabled != storageWatchEnabled else { return }
        storageWatchInFlight = true
        errorMessage = nil
        let root = projectRoot
        let command = enabled ? "--install" : "--uninstall"
        Task {
            let result = await LocalProcessRunner.capture(
                executable: "/bin/bash",
                arguments: ["./scripts/schedule.sh", command, "--owner-approved"],
                currentDirectory: root
            )
            storageWatchInFlight = false
            let values = Self.protocolValues(result.output)
            if result.status == 0, let value = values["enabled"] {
                storageWatchEnabled = value == "true"
                storageWatchDetail = storageWatchEnabled
                    ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
                    : "꺼짐 · 자동 삭제 없음"
                appendLog(storageWatchEnabled ? "저장공간 급감 감시를 켰습니다." : "저장공간 급감 감시를 껐습니다.")
            } else {
                errorMessage = "저장공간 감시 설정을 변경하지 못했습니다. 실행 로그를 확인하세요."
            }
        }
    }

    func copyCleanupGuide() {
        guard let storage else { return }
        let candidates = (storage.cleanupCandidates + storage.reviewCandidates + storage.developerToolchains).prefix(16)
        let lines = candidates.map { cleanupGuide(for: $0) }
        let text = """
        PC 건강검진 Mac Edition 정리 가이드

        원칙:
        - 삭제는 자동 실행하지 않으며, 앱의 고정 레시피도 미리보기와 개별 승인을 거칩니다.
        - Finder에서 위치를 확인하고, 실행 중인 앱/Xcode/Simulator/브라우저를 먼저 종료하세요.
        - Android SDK, Simulator runtime, 언어 toolchain은 프로젝트 요구 버전을 확인하기 전 통째 삭제하지 마세요.

        \(lines.joined(separator: "\n\n"))
        """
        copyToPasteboard(text)
    }

    func copyFullDiskAccessGuide() {
        let text = """
        PC 건강검진 Mac Edition - Full Disk Access 안내

        macOS는 Mail, Messages, Safari, 앱 컨테이너 같은 일부 영역을 개인정보 보호 설정으로 숨길 수 있습니다.
        리포트가 비어 보이거나 일부 앱 데이터가 빠진다면:

        1. 시스템 설정을 엽니다.
        2. 개인정보 보호 및 보안 > 전체 디스크 접근 권한으로 이동합니다.
        3. PC Health Check Mac 앱 또는 Terminal을 허용합니다.
        4. 앱을 다시 실행한 뒤 검사를 다시 돌립니다.

        이 권한은 읽기 범위를 넓히기 위한 것이며, PC Health Check는 삭제를 자동 실행하지 않습니다.
        """
        copyToPasteboard(text)
    }

    func clearLog() {
        logStore.clear()
    }

    private func cleanupGuide(for item: StorageItem) -> String {
        """
        \(item.label) (\(item.sizeText))
        경로: \(item.path)
        분류: \(item.kind)
        권장 확인: \(item.action)
        설명: \(item.note)
        """
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        appendLog("클립보드에 복사했습니다.")
    }

}
