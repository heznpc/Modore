import AppKit
import Foundation
@preconcurrency import UserNotifications

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
        guard let url = selectedReportURL, reportURLIsSafe(url) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealReportsInFinder() {
        let target: URL
        if let selectedReportURL, reportURLIsSafe(selectedReportURL) {
            target = selectedReportURL
        } else {
            target = hasNormalReport ? normalReportURL : projectRoot
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func openConfigInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([RuntimeWorkspace.userConfigURL()])
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
        guard !isSimulatorProtected(device), device.hasSupportedCleanupRecipe else { return }
        prepareCleanup(recipeID: device.cleanupID, label: device.name)
    }

    func isSimulatorProtected(_ device: SimulatorDevice) -> Bool {
        device.isProtected(by: simulatorKeepUUIDs) || hasUnresolvedSimulatorKeepEntries
    }

    func toggleSimulatorProtection(_ device: SimulatorDevice) {
        guard !device.isBooted else { return }
        guard !hasUnresolvedSimulatorKeepEntries else {
            errorMessage = "기존 Simulator 보존 항목을 UUID로 확인하지 못해 변경을 차단했습니다. Simulator 목록을 확인한 뒤 다시 검사하세요."
            return
        }
        var updatedUUIDs = simulatorKeepUUIDs
        let normalizedUUID = device.uuid.uppercased()
        let isRemoving = updatedUUIDs.contains(normalizedUUID)
        if isRemoving {
            updatedUUIDs.remove(normalizedUUID)
        } else {
            updatedUUIDs.insert(normalizedUUID)
        }
        do {
            try SimulatorKeepStore.save(updatedUUIDs)
            replaceSimulatorKeepUUIDs(with: updatedUUIDs)
            appendLog(isRemoving ? "Simulator 보존 해제: \(device.name)" : "Simulator 보존: \(device.name)")
            AccessibilityAnnouncer.announce(
                isRemoving ? "\(device.name) 보존을 해제했습니다" : "\(device.name) 보존을 설정했습니다"
            )
        } catch {
            errorMessage = "Simulator 보존 목록을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func prepareCleanup(recipeID: String, label: String) {
        guard !applicationTerminationStarted, !recipeID.isEmpty, !isBusy else { return }
        cleanupInFlight = true
        cleanupIsExecuting = false
        errorMessage = nil
        appendLog("정리 미리보기: \(label)")
        let root = projectRoot
        cleanupTask = Task {
            defer {
                cleanupInFlight = false
                cleanupTask = nil
            }
            let context = await CleanupExecutionService.prepare(projectRoot: root)
            guard !Task.isCancelled else {
                appendLog("정리 미리보기를 취소했습니다.")
                return
            }
            guard let context else {
                errorMessage = "서명된 정리 런타임을 다시 검증하지 못했습니다. 앱을 다시 설치한 뒤 시도하세요."
                appendLog("정리 미리보기 중단: 런타임 신뢰 검증 실패")
                return
            }
            let result = await CleanupExecutionService.preview(recipeID: recipeID, using: context)
            guard result.endState == .exited else {
                if result.endState == .cancelled {
                    appendLog("정리 미리보기를 취소했습니다.")
                } else {
                    errorMessage = "정리 대상을 제한 시간과 출력 상한 안에서 확인하지 못했습니다. 다시 시도하세요."
                    appendLog("정리 미리보기 중단: \(result.endState)")
                }
                return
            }
            guard let preview = CleanupPreview(protocolText: result.output) else {
                errorMessage = "정리 미리보기 결과를 읽지 못했습니다. 실행 로그를 확인하세요."
                appendLog("정리 미리보기 실패: \(result.status)")
                return
            }
            cleanupPreview = preview
            appendLog(
                preview.estimateMeasured
                    ? "미리보기: \(preview.statusText), 대상 점유 추정 \(preview.estimatedText)"
                    : "미리보기: \(preview.statusText), 크기 재측정 보류(종료할 작업 있음)"
            )
        }
    }

    func executeCleanup(_ preview: CleanupPreview) {
        guard !applicationTerminationStarted,
              preview.canExecute,
              !isBusy,
              cleanupPreview?.recipeID == preview.recipeID,
              cleanupPreview?.approvalToken == preview.approvalToken else { return }
        cleanupInFlight = true
        beginDestructiveCleanupTransaction()
        errorMessage = nil
        appendLog("승인형 정리 실행: \(preview.label)")
        let root = projectRoot
        cleanupTask = Task {
            defer {
                cleanupInFlight = false
                finishDestructiveCleanupTransaction()
                cleanupTask = nil
            }
            guard let context = await CleanupExecutionService.prepare(projectRoot: root) else {
                errorMessage = "서명된 정리 런타임을 다시 검증하지 못해 실행을 중단했습니다. 아무것도 정리하지 않았습니다."
                appendLog("정리 실행 중단: 런타임 신뢰 검증 실패")
                return
            }
            guard let result = await CleanupExecutionService.execute(preview, using: context) else {
                errorMessage = "내부 오류: 고정 파일 키가 충돌해 정리를 실행하지 않았습니다."
                return
            }
            guard result.endState == .exited else {
                errorMessage = "정리 실행이 제한 시간 안에 끝나지 않아 중단했습니다. 격리된 항목이 있다면 \(CleanupExecutionService.stagingRecoveryDisplayPath)에서 확인할 수 있습니다."
                appendLog("정리 실행 중단: \(result.endState) · 격리 복구 경로 \(CleanupExecutionService.stagingRecoveryDisplayPath)")
                return
            }
            guard let executed = CleanupPreview(protocolText: result.output) else {
                errorMessage = "정리 실행 결과를 읽지 못했습니다. 다시 실행하기 전에 \(CleanupExecutionService.stagingRecoveryDisplayPath)와 로그를 확인하세요."
                appendLog("정리 실행 결과 해석 실패: \(result.status)")
                return
            }
            if result.status == 0 && executed.isComplete {
                if executed.actionMode == "trash" {
                    appendLog("휴지통 이동 완료: \(executed.reclaimedText). 휴지통을 비운 뒤 실제 공간이 회수됩니다.")
                } else {
                    appendLog("정리 완료: 처리 대상 점유 \(executed.reclaimedText), 실제 여유 변화 \(executed.physicalDeltaText)")
                }
                if !executed.receipt.isEmpty {
                    appendLog("영수증: \(executed.receipt)")
                }
                AccessibilityAnnouncer.announce(
                    executed.actionMode == "trash" ? "휴지통 이동 완료" : "정리 완료"
                )
                cleanupPreview = nil
                state = .running
                let result = await ScanPipeline.run(projectRoot: root) { line in
                    Task { @MainActor in self.appendLog(line) }
                }
                await finishRun(result: result)
            } else {
                cleanupPreview = executed
                errorMessage = executed.failureMessage
                for recoveryPath in executed.recoveryPathMessages {
                    appendLog(recoveryPath)
                }
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

    func prepareRecoveryPlan(_ items: [StorageItem], desiredFreeGB: Double) {
        guard !applicationTerminationStarted, !isBusy, desiredFreeGB > 0 else { return }
        var seenExecutions: Set<String> = []
        let candidates = items.compactMap {
            item -> (item: StorageItem, tier: CleanupTier, request: CleanupExecutionRequest?)? in
            guard let tier = item.cleanupTier, !item.cleanupID.isEmpty else { return nil }
            let request = CleanupExecutionRequest(item: item)
            if item.cleanupID == "project_residue", request == nil { return nil }
            let key = item.cleanupID + "\u{0}" + (request?.target ?? "")
            guard seenExecutions.insert(key).inserted else { return nil }
            return (item, tier, request)
        }
        guard !candidates.isEmpty else {
            errorMessage = "한 번에 실행할 수 있는 캐시·재생성 후보가 없습니다. 개별 검토 항목은 정리 화면에서 확인하세요."
            return
        }

        cleanupInFlight = true
        cleanupIsExecuting = false
        cleanupRecoveryResult = nil
        cleanupRecoveryProgress = CleanupRecoveryProgress(
            completedCount: 0,
            totalCount: candidates.count,
            currentLabel: "실제 정리 대상을 다시 측정하는 중"
        )
        errorMessage = nil
        appendLog("공간 확보 계획 준비: \(candidates.count)개 후보")
        let root = projectRoot
        let fallbackFreeGB = currentFreeGB ?? 0

        cleanupTask = Task {
            defer {
                cleanupInFlight = false
                cleanupRecoveryProgress = nil
                cleanupTask = nil
            }
            guard let context = await CleanupExecutionService.prepare(projectRoot: root) else {
                errorMessage = "서명된 정리 런타임을 다시 검증하지 못해 계획을 만들지 않았습니다."
                appendLog("공간 확보 계획 중단: 런타임 신뢰 검증 실패")
                return
            }

            var entries: [CleanupPlanEntry] = []
            for (index, candidate) in candidates.enumerated() {
                guard !Task.isCancelled else {
                    appendLog("공간 확보 계획 준비를 취소했습니다.")
                    return
                }
                cleanupRecoveryProgress = CleanupRecoveryProgress(
                    completedCount: index,
                    totalCount: candidates.count,
                    currentLabel: candidate.item.label
                )
                let result = await CleanupExecutionService.preview(
                    recipeID: candidate.item.cleanupID,
                    request: candidate.request,
                    using: context
                )
                guard result.endState == .exited,
                      let preview = CleanupPreview(protocolText: result.output) else {
                    errorMessage = "\(candidate.item.label)의 정리 대상을 안전하게 확인하지 못해 계획을 만들지 않았습니다."
                    appendLog("공간 확보 계획 중단: \(candidate.item.label) 미리보기 실패")
                    return
                }
                entries.append(CleanupPlanEntry(
                    preview: preview,
                    tier: candidate.tier,
                    request: candidate.request
                ))
                appendLog("계획 측정: \(preview.label) · \(preview.statusText) · \(preview.estimatedText)")
            }

            let currentObservation = await Task.detached(priority: .utility) {
                LiveStateService.observeFreeSpace()
            }.value
            let baselineFreeGB = currentObservation?.value.freeGB ?? fallbackFreeGB
            if let currentObservation {
                recordLiveFreeSpaceObservation(currentObservation)
            }
            cleanupRecoveryPlan = CleanupRecoveryPlan(
                baselineFreeGB: baselineFreeGB,
                desiredFreeGB: desiredFreeGB,
                entries: entries
            )
            appendLog("공간 확보 계획 준비 완료: 재측정 \(entries.count)개")
            AccessibilityAnnouncer.announce("공간 확보 계획을 준비했습니다")
        }
    }

    func executeRecoveryPlan(_ plan: CleanupRecoveryPlan) {
        guard !applicationTerminationStarted,
              !isBusy,
              !plan.readyEntries.isEmpty,
              cleanupRecoveryPlan?.id == plan.id,
              cleanupRecoveryPlan?.entries.map({ $0.preview.approvalToken })
                == plan.entries.map({ $0.preview.approvalToken }) else { return }
        guard plan.canExecute(at: Date()) else {
            appendLog("공간 확보 계획의 승인이 만료되어 실행 전에 다시 측정합니다.")
            retryRecoveryPlan(plan)
            return
        }

        cleanupInFlight = true
        beginDestructiveCleanupTransaction()
        cleanupRecoveryResult = nil
        cleanupRecoveryProgress = CleanupRecoveryProgress(
            completedCount: 0,
            totalCount: plan.readyEntries.count,
            currentLabel: "승인한 계획을 시작하는 중"
        )
        errorMessage = nil
        appendLog("공간 확보 계획 실행 승인: \(plan.readyEntries.count)개")
        let root = projectRoot

        cleanupTask = Task {
            var shouldRescan = false
            defer {
                cleanupInFlight = false
                cleanupRecoveryProgress = nil
                finishDestructiveCleanupTransaction()
                cleanupTask = nil
                if shouldRescan {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        self?.runScan()
                    }
                }
            }
            guard let context = await CleanupExecutionService.prepare(projectRoot: root) else {
                errorMessage = "서명된 정리 런타임을 다시 검증하지 못해 아무것도 정리하지 않았습니다."
                appendLog("공간 확보 실행 중단: 런타임 신뢰 검증 실패")
                return
            }

            var itemResults: [CleanupRecoveryItemResult] = []
            var stoppedAfterFailure = false
            var latestFreeGB = plan.baselineFreeGB
            var freeSpaceMeasured = false

            for (index, entry) in plan.readyEntries.enumerated() {
                guard entry.preview.approvalIsFresh(
                    at: Date(),
                    minimumRemaining: CleanupRecoveryPlan.minimumApprovalValidity
                ) else {
                    stoppedAfterFailure = true
                    errorMessage = "남은 항목의 승인이 만료되어 실행을 중단했습니다. 남은 후보를 다시 측정하세요."
                    appendLog("공간 확보 중단: \(entry.preview.label) 승인 만료")
                    break
                }
                let before = await Task.detached(priority: .utility) {
                    LiveStateService.observeFreeSpace()
                }.value
                guard let before else {
                    stoppedAfterFailure = true
                    errorMessage = "현재 여유 공간을 확인하지 못해 남은 계획을 실행하지 않았습니다."
                    appendLog("공간 확보 중단: 실행 전 여유 공간 측정 실패")
                    break
                }
                latestFreeGB = before.value.freeGB
                freeSpaceMeasured = true
                recordLiveFreeSpaceObservation(before)
                if latestFreeGB >= plan.desiredFreeGB {
                    appendLog("확보 목표에 도달해 남은 \(plan.readyEntries.count - index)개 항목은 실행하지 않았습니다.")
                    break
                }

                cleanupRecoveryProgress = CleanupRecoveryProgress(
                    completedCount: index,
                    totalCount: plan.readyEntries.count,
                    currentLabel: entry.preview.label
                )
                appendLog("계획 정리 실행: \(entry.preview.label)")
                freeSpaceMeasured = false
                guard let result = await CleanupExecutionService.execute(
                    entry.preview,
                    request: entry.request,
                    using: context
                ) else {
                    itemResults.append(CleanupRecoveryItemResult(
                        recipeID: entry.preview.recipeID,
                        requestTarget: entry.request?.target ?? "",
                        label: entry.preview.label,
                        status: "failed",
                        reclaimedKB: 0,
                        physicalDeltaKB: 0,
                        receipt: "",
                        detail: "고정 실행 입력을 구성하지 못했습니다."
                    ))
                    stoppedAfterFailure = true
                    errorMessage = "내부 실행 입력 검증이 실패해 남은 계획을 실행하지 않았습니다."
                    appendLog("공간 확보 중단: \(entry.preview.label) 실행 입력 검증 실패")
                    break
                }
                guard result.endState == .exited else {
                    itemResults.append(CleanupRecoveryItemResult(
                        recipeID: entry.preview.recipeID,
                        requestTarget: entry.request?.target ?? "",
                        label: entry.preview.label,
                        status: "failed",
                        reclaimedKB: 0,
                        physicalDeltaKB: 0,
                        receipt: "",
                        detail: "실행이 제한 시간 안에 끝나지 않았습니다. 격리 복구 경로: \(CleanupExecutionService.stagingRecoveryDisplayPath)"
                    ))
                    stoppedAfterFailure = true
                    errorMessage = "정리 실행이 제한 시간 안에 끝나지 않아 남은 계획을 중단했습니다."
                    appendLog("공간 확보 중단: \(entry.preview.label) · \(result.endState) · 격리 복구 경로 \(CleanupExecutionService.stagingRecoveryDisplayPath)")
                    break
                }
                guard
                      let executed = CleanupPreview(protocolText: result.output) else {
                    itemResults.append(CleanupRecoveryItemResult(
                        recipeID: entry.preview.recipeID,
                        requestTarget: entry.request?.target ?? "",
                        label: entry.preview.label,
                        status: "failed",
                        reclaimedKB: 0,
                        physicalDeltaKB: 0,
                        receipt: "",
                        detail: "정리 실행 결과를 안전하게 읽지 못했습니다."
                    ))
                    stoppedAfterFailure = true
                    errorMessage = "정리 실행 결과를 확인하지 못했습니다. 남은 계획은 실행하지 않았습니다."
                    appendLog("공간 확보 중단: \(entry.preview.label) 결과 해석 실패")
                    break
                }

                let succeeded = result.status == 0 && executed.isComplete
                itemResults.append(CleanupRecoveryItemResult(
                    recipeID: executed.recipeID,
                    requestTarget: entry.request?.target ?? "",
                    label: executed.label,
                    status: executed.status,
                    reclaimedKB: executed.reclaimedKB,
                    physicalDeltaKB: executed.physicalDeltaKB,
                    receipt: executed.receipt,
                    detail: succeeded ? "" : executed.failureMessage
                ))
                if succeeded {
                    shouldRescan = true
                    appendLog("계획 정리 완료: \(executed.label) · 실제 여유 변화 \(executed.physicalDeltaText)")
                } else {
                    stoppedAfterFailure = true
                    errorMessage = executed.failureMessage
                    appendLog("공간 확보 중단: \(executed.label) · \(executed.statusText)")
                    break
                }

                let after = await Task.detached(priority: .utility) {
                    LiveStateService.observeFreeSpace()
                }.value
                guard let after else {
                    stoppedAfterFailure = true
                    errorMessage = "정리 후 실제 여유 공간을 확인하지 못해 남은 계획을 실행하지 않았습니다."
                    appendLog("공간 확보 중단: 정리 후 여유 공간 측정 실패")
                    break
                }
                latestFreeGB = after.value.freeGB
                freeSpaceMeasured = true
                recordLiveFreeSpaceObservation(after)
                cleanupRecoveryProgress = CleanupRecoveryProgress(
                    completedCount: index + 1,
                    totalCount: plan.readyEntries.count,
                    currentLabel: "실제 여유 공간 확인 중"
                )
            }

            let finalObservation = await Task.detached(priority: .utility) {
                LiveStateService.observeFreeSpace()
            }.value
            if let finalObservation {
                latestFreeGB = finalObservation.value.freeGB
                freeSpaceMeasured = true
                recordLiveFreeSpaceObservation(finalObservation)
            }
            cleanupRecoveryResult = CleanupRecoveryResult(
                baselineFreeGB: plan.baselineFreeGB,
                finalFreeGB: latestFreeGB,
                desiredFreeGB: plan.desiredFreeGB,
                freeSpaceMeasured: freeSpaceMeasured,
                plannedCount: plan.readyEntries.count,
                items: itemResults,
                stoppedAfterFailure: stoppedAfterFailure,
                rescanScheduled: shouldRescan
            )
            if freeSpaceMeasured {
                let gain = max(0, latestFreeGB - plan.baselineFreeGB)
                appendLog(String(format: "공간 확보 확인: 실제 %.1fGB 증가 · 현재 %.1fGB", gain, latestFreeGB))
            } else {
                appendLog("공간 확보 결과의 실제 여유 공간을 확인하지 못했습니다.")
            }
            AccessibilityAnnouncer.announce(
                freeSpaceMeasured && latestFreeGB >= plan.desiredFreeGB
                    ? "공간 확보 목표를 달성했습니다"
                    : "공간 확보 실행을 마쳤습니다"
            )
        }
    }

    func retryRecoveryPlan(_ plan: CleanupRecoveryPlan) {
        guard !cleanupInFlight, cleanupRecoveryPlan?.id == plan.id else { return }
        let candidates = storage?.recoveryCandidates ?? []
        let items = plan.entries.compactMap { entry in
            candidates.first {
                $0.cleanupID == entry.preview.recipeID
                    && (entry.request == nil || $0.path == entry.request?.target)
            }
        }
        prepareRecoveryPlan(items, desiredFreeGB: plan.desiredFreeGB)
    }

    func dismissRecoveryPlan() {
        guard !cleanupInFlight else { return }
        cleanupRecoveryPlan = nil
        cleanupRecoveryProgress = nil
        cleanupRecoveryResult = nil
    }

    func setStorageWatchEnabled(_ enabled: Bool) {
        guard !applicationTerminationStarted,
              !storageWatchInFlight,
              enabled != storageWatchEnabled else { return }
        storageWatchInFlight = true
        errorMessage = nil
        let root = projectRoot
        let command = enabled ? "--install" : "--uninstall"
        startTrackedApplicationTask { [weak self] in
            guard let self else { return }
            defer { storageWatchInFlight = false }
            // Ask now, in this clear foreground moment the owner just triggered —
            // never from the scheduled launch itself, which runs invisibly and
            // would turn a routine hourly tick into a surprise permission dialog.
            // The scheduled launch only posts if this already resolved to
            // .authorized by the time it runs; a denial here just means it keeps
            // falling back to the existing osascript notification, same as today.
            if enabled {
                _ = try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
            }
            let execution = await Task.detached(priority: .userInitiated) {
                RuntimeWorkspace.prepareExecution(projectRoot: root)
            }.value
            guard let execution else {
                errorMessage = "서명된 감시 런타임을 확인하지 못해 설정을 변경하지 않았습니다."
                return
            }
            guard let invocation = execution.pinnedInvocation(
                relativePath: "scripts/schedule.sh",
                name: "schedule"
            ), let supportModule = execution.pinnedSupportDirectoryModule() else {
                errorMessage = "봉인한 감시 설정 프로그램을 확인하지 못해 변경하지 않았습니다."
                return
            }
            guard let watcherHash = execution.sealedSHA256(
                relativePath: "scripts/storage_watch.sh"
            ) else {
                errorMessage = "봉인한 저장공간 감시 프로그램을 확인하지 못해 변경하지 않았습니다."
                return
            }
            let result = await LocalProcessRunner.capture(
                executable: "/bin/bash",
                arguments: [invocation.argument, command, "--owner-approved"],
                currentDirectory: execution.runtimeRoot,
                expectedCurrentDirectoryIdentity: execution.runtimeRootIdentity,
                expectedSignedBundleURL: execution.signedBundleURL,
                pinnedFiles: invocation.files.merging(supportModule.files) { current, _ in current },
                environment: supportModule.environment.merging([
                    "PCH_STORAGE_WATCH_SCRIPT": execution.storageWatchScriptURL.path,
                    "PCH_STORAGE_WATCH_SHA256": watcherHash,
                    "PCH_STORAGE_WATCH_APP_BUNDLE": Bundle.main.bundleURL.path,
                ]) { current, _ in current }
            )
            let values = StorageWatchService.protocolValues(result.output)
            let harnessEnabled = values["enabled"] == "true"
            let runtimeState = StorageWatchService.runtimeState(
                protocolValues: values,
                expectedWatcherURL: execution.storageWatchScriptURL,
                expectedWatcherSHA256: watcherHash
            )
            let stateMatchesRequest = enabled
                ? harnessEnabled && runtimeState == .current
                : !harnessEnabled && runtimeState == .absent
            if result.status == 0, let value = values["enabled"], stateMatchesRequest {
                storageWatchEnabled = value == "true"
                storageWatchDetail = storageWatchEnabled
                    ? "매시간 확인 · 20GB 미만 또는 8GB 급감 시 알림"
                    : "꺼짐 · 자동 삭제 없음"
                appendLog(storageWatchEnabled ? "저장공간 급감 감시를 켰습니다." : "저장공간 급감 감시를 껐습니다.")
                AccessibilityAnnouncer.announce(
                    storageWatchEnabled ? "저장공간 감시를 켰습니다" : "저장공간 감시를 껐습니다"
                )
            } else {
                storageWatchEnabled = false
                storageWatchDetail = runtimeState == .stale
                    ? "안전하지 않은 감시 plist가 남아 있습니다. 제거 후 다시 시도하세요."
                    : "꺼짐 · 자동 삭제 없음"
                errorMessage = runtimeState == .stale
                    ? "감시 LaunchAgent가 현재 서명된 앱 경로를 가리키지 않거나 안전하지 않아 작업을 완료하지 않았습니다."
                    : "저장공간 감시 설정을 변경하지 못했습니다. 실행 로그를 확인하세요."
            }
        }
    }

    func copyCleanupGuide() {
        guard let storage else { return }
        let candidates = (storage.cleanupCandidates + storage.reviewCandidates + storage.developerToolchains).prefix(16)
        let lines = candidates.map { cleanupGuide(for: $0) }
        let text = """
        Modore 정리 가이드

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
        Modore - Full Disk Access 안내

        macOS는 Mail, Messages, Safari, 앱 컨테이너 같은 일부 영역을 개인정보 보호 설정으로 숨길 수 있습니다.
        리포트가 비어 보이거나 일부 앱 데이터가 빠진다면:

        1. 시스템 설정을 엽니다.
        2. 개인정보 보호 및 보안 > 전체 디스크 접근 권한으로 이동합니다.
        3. Modore 앱 또는 Terminal을 허용합니다.
        4. 앱을 다시 실행한 뒤 검사를 다시 돌립니다.

        이 권한은 읽기 범위를 넓히기 위한 것이며, Modore는 삭제를 자동 실행하지 않습니다.
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
