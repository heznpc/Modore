import Foundation

extension ScanModel {
    func prepareBrowserAutomationStop(signal: RuntimeSignal) {
        guard signal.kind == "browser_automation_root",
              signal.pid > 1,
              !isBusy,
              browserAutomationStopPreview == nil else { return }
        browserAutomationStopInFlight = true
        errorMessage = nil
        appendLog("자동화 브라우저 종료 근거 재확인: PID \(signal.pid)")
        browserAutomationStopTask = Task {
            do {
                let preview = try await BrowserAutomationControl.preview(signal: signal)
                guard !Task.isCancelled else {
                    browserAutomationStopInFlight = false
                    browserAutomationStopTask = nil
                    return
                }
                browserAutomationStopPreview = preview
                appendLog(
                    "종료 미리보기: PID \(preview.pid), \(preview.processCount)개 프로세스, 메모리 \(preview.treeMemoryText)"
                )
            } catch {
                errorMessage = error.localizedDescription
                appendLog("자동화 브라우저 보호: \(error.localizedDescription)")
            }
            browserAutomationStopInFlight = false
            browserAutomationStopTask = nil
        }
    }

    func executeBrowserAutomationStop(_ preview: BrowserAutomationStopPreview) {
        guard !isBusy,
              browserAutomationStopPreview?.id == preview.id else { return }
        browserAutomationStopInFlight = true
        browserAutomationStopIsExecuting = true
        errorMessage = nil
        appendLog("승인형 정상 종료 요청: 자동화 브라우저 PID \(preview.pid)")
        browserAutomationStopTask = Task {
            do {
                try await BrowserAutomationControl.stop(preview)
                appendLog("자동화 브라우저 정상 종료 확인: PID \(preview.pid)")
                browserAutomationStopPreview = nil
                browserAutomationStopInFlight = false
                browserAutomationStopIsExecuting = false
                browserAutomationStopTask = nil
                runScan()
            } catch {
                errorMessage = error.localizedDescription
                appendLog("자동화 브라우저 종료 중단: \(error.localizedDescription)")
                // stop() revalidates the target identity and only throws when the
                // previewed evidence (PID/identity) no longer describes a live
                // process. Clear it so the approval sheet cannot keep offering a
                // destructive action against evidence just proven invalid.
                browserAutomationStopPreview = nil
                browserAutomationStopInFlight = false
                browserAutomationStopIsExecuting = false
                browserAutomationStopTask = nil
            }
        }
    }

    func dismissBrowserAutomationStopPreview() {
        guard !browserAutomationStopInFlight else { return }
        browserAutomationStopPreview = nil
    }
}
