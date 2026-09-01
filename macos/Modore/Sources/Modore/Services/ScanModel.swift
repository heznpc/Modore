import Darwin
import Foundation
import SwiftUI

struct ScanOutputBatch: Equatable, Sendable {
    let lines: [String]
    let omittedLineCount: Int

    var text: String {
        var output = lines
        if omittedLineCount > 0 {
            output.insert(
                "[검사 출력 \(omittedLineCount)줄의 일부 또는 전부를 버퍼 상한으로 생략했습니다.]",
                at: 0
            )
        }
        return output.joined(separator: "\n")
    }
}

/// A scan subprocess may emit close to the runner's two-megabyte output cap as
/// one-byte lines. Crossing the actor once per line would enqueue millions of
/// unstructured tasks. Keep one bounded newest-output buffer instead and use a
/// single coalesced stream signal to wake the scan task that owns the process.
final class BoundedScanOutputBuffer: @unchecked Sendable {
    private struct BufferedLine {
        let text: String
        let byteCount: Int
    }

    private let maximumBufferedBytes: Int
    private let maximumBufferedLines: Int
    private let lock = NSLock()
    private var bufferedLines: [BufferedLine] = []
    private var bufferedByteCount = 0
    private var omittedLineCount = 0
    private var signalPending = false
    private var acceptingOutput = true
    private let continuation: AsyncStream<Void>.Continuation
    let events: AsyncStream<Void>

    init(
        maximumBufferedBytes: Int = 64 * 1_024,
        maximumBufferedLines: Int = 256
    ) {
        self.maximumBufferedBytes = max(1, maximumBufferedBytes)
        self.maximumBufferedLines = max(1, maximumBufferedLines)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func send(_ line: String) {
        let rawBytes = line.utf8
        let boundedText: String
        let truncated = rawBytes.count > maximumBufferedBytes
        if truncated {
            boundedText = String(
                decoding: rawBytes.suffix(maximumBufferedBytes),
                as: UTF8.self
            )
        } else {
            boundedText = line
        }
        let byteCount = boundedText.utf8.count
        var shouldSignal = false

        lock.lock()
        guard acceptingOutput else {
            lock.unlock()
            return
        }
        if truncated { omittedLineCount += 1 }
        while !bufferedLines.isEmpty,
              bufferedLines.count >= maximumBufferedLines
                || bufferedByteCount + byteCount > maximumBufferedBytes {
            bufferedByteCount -= bufferedLines.removeFirst().byteCount
            omittedLineCount += 1
        }
        bufferedLines.append(BufferedLine(text: boundedText, byteCount: byteCount))
        bufferedByteCount += byteCount
        if !signalPending {
            signalPending = true
            shouldSignal = true
        }
        lock.unlock()

        if shouldSignal { continuation.yield(()) }
    }

    func takeBatch() -> ScanOutputBatch? {
        lock.lock()
        guard signalPending else {
            lock.unlock()
            return nil
        }
        let batch = ScanOutputBatch(
            lines: bufferedLines.map(\.text),
            omittedLineCount: omittedLineCount
        )
        bufferedLines.removeAll(keepingCapacity: true)
        bufferedByteCount = 0
        omittedLineCount = 0
        signalPending = false
        lock.unlock()
        return batch
    }

    func finish() {
        lock.lock()
        acceptingOutput = false
        let shouldSignalFinalBatch = signalPending
        lock.unlock()
        // A custom runner may return while a concurrently invoked callback is
        // between unlocking `send` and yielding its wake signal. Re-yielding a
        // single buffered signal here makes that final batch observable before
        // the stream closes; bufferingNewest(1) coalesces the normal duplicate.
        if shouldSignalFinalBatch { continuation.yield(()) }
        continuation.finish()
    }

    func cancel() {
        lock.lock()
        acceptingOutput = false
        bufferedLines.removeAll(keepingCapacity: false)
        bufferedByteCount = 0
        omittedLineCount = 0
        signalPending = false
        lock.unlock()
        continuation.finish()
    }
}

@MainActor
final class ScanModel: ObservableObject {
    typealias ScanRunner = @Sendable (
        URL,
        @escaping @Sendable (String) -> Void
    ) async -> ScanRunResult
    typealias ExistingResultsLoader = @Sendable (URL) async -> LoadedScanResult
    typealias StorageWatchEvidenceLoader = @Sendable () async -> StorageWatchEvidenceSnapshot?
    typealias CleanupMutationRecorder = @Sendable (URL) -> Bool

    enum TrackedTaskScope: Hashable {
        case workScreen
        case activityScreen
        case application
    }

    struct TrackedApplicationTask {
        let scope: TrackedTaskScope
        let task: Task<Void, Never>
    }

    @Published var state: ScanState = .idle
    @Published private(set) var deepScanSnapshot = DeepScanSnapshot.empty
    @Published var selectedReportURL: URL?
    @Published var selectedReportTitle = "리포트"
    @Published var errorMessage: String?
    @Published var reportRevision = 0
    @Published var virusTotalEnabled = false
    @Published var cleanupPreview: CleanupPreview?
    @Published var cleanupRecoveryPlan: CleanupRecoveryPlan?
    @Published var cleanupRecoveryProgress: CleanupRecoveryProgress?
    @Published var cleanupRecoveryResult: CleanupRecoveryResult?
    @Published var cleanupInFlight = false
    @Published var cleanupIsExecuting = false
    @Published var browserAutomationStopPreview: BrowserAutomationStopPreview?
    @Published var browserAutomationStopInFlight = false
    @Published var browserAutomationStopIsExecuting = false
    @Published private(set) var storageHistory: [StorageHistoryEntry] = []
    @Published private(set) var storageChange: StorageChangeSummary?
    @Published private(set) var displayedStorageEntry: StorageHistoryEntry?
    @Published private(set) var freeSpaceSamples: [FreeSpaceSample] = []
    @Published private(set) var storageWatchPathEvents: [StorageWatchPathEvent] = []
    @Published private(set) var storageWatchSignalEvents: [StorageWatchSignalEvent] = []
    @Published private(set) var simulatorKeepUUIDs: Set<String> = []
    @Published private(set) var simulatorLegacyKeepEntries: Set<String> = []
    @Published var storageWatchEnabled = false
    @Published var storageWatchDetail = "상태 확인 중"
    @Published var storageWatchHealthState: StorageWatchHealthState = .neverAttempted
    @Published var storageWatchInFlight = false
    @Published private(set) var storageWatchCommittedEvidenceAt: Date?
    private var storageWatchEvidenceGeneration = 0
    var latestStorageWatchEvidence: StorageWatchEvidenceEvent? {
        guard let storageWatchCommittedEvidenceAt else { return nil }
        return StorageWatchEvidenceEvent.latest(
            pathEvents: storageWatchPathEvents,
            signalEvents: storageWatchSignalEvents,
            committedAt: storageWatchCommittedEvidenceAt
        )
    }
    @Published private(set) var resultLoading = true
    @Published private(set) var reportState = ReportState.unknown
    @Published private(set) var liveState = LiveState.unobserved
    @Published private(set) var deepScanFailure: DeepScanFailure?
    @Published private(set) var deepScanAt: Date?
    @Published private(set) var cleanupMutationPending = false
    @Published var screeReport: ScreeReport?
    @Published var screeReportRevision = 0
    @Published var screeLoading = false
    @Published var screeError: String?
    /// The Work screen owns its automatic audit. Keeping both the task and
    /// a generation prevents a cancelled/superseded subprocess from writing
    /// a late result after the person has left the screen.
    var screeGeneration = 0
    var screeTask: Task<Void, Never>?
    /// True only while a requested refresh has not produced a current success
    /// or explicit failure. Screen cancellation keeps this true so re-entry
    /// cannot present the previous report indefinitely as if it were current.
    var screeNeedsRefresh = true
    @Published var screePreserveInFlightSource: String?
    /// Every repo the scan judged, archivable or not. Named for what it
    /// is: `rankCandidates` drops `.unsafe` repos, which is right for a
    /// retirement list and wrong as a project's git state.
    @Published var repoAssessments: [ArchiveCandidate]?
    /// Repo path to why it could not be read, and the repos the scan's
    /// root cap never reached. Both travel per path: a total says
    /// something somewhere is untrustworthy, only a path says which row.
    @Published var repoScanFailures: [String: String] = [:]
    @Published var reposNotScanned: [String] = []
    /// Conversations a person opened, and how each fetch went, keyed by
    /// the transcript's byte identity rather than its path -- see
    /// `loadConversation`. Display-only cache; never consulted by any
    /// judgment.
    @Published var conversationLoads: [String: ConversationLoadState] = [:]
    var conversationLoadTokens: [String: UUID] = [:]
    /// The session browser's index, and how fetching it went.
    @Published var sessionIndex: SessionIndex?
    @Published var sessionIndexLoading = false
    @Published var sessionIndexError: String?
    var sessionIndexGeneration = 0
    var sessionIndexTask: Task<Void, Never>?
    var sessionIndexNeedsRefresh = true
    /// What the person typed into the browser's search field.
    @Published var sessionSearch = ""
    /// Content-search results, and whether one is running. Separate from
    /// `sessionSearch` because typing filters metadata instantly while
    /// reading transcript bodies waits for an explicit return.
    @Published var contentSearch: SessionSearchResult?
    @Published var contentSearchRunning = false
    @Published var contentSearchError: String?
    /// Which search request is current. A result from an older one is
    /// dropped rather than written under a query nobody asked.
    var contentSearchGeneration = 0
    var contentSearchTask: Task<Void, Never>?
    /// Storage incident evidence is an explicit transcript-body query,
    /// separate from the always-local known-root snapshot above it.
    @Published var storageEvidenceQuery = ""
    @Published var storageEvidence: ScreeEvidenceResult?
    @Published var storageEvidenceRunning = false
    @Published var storageEvidenceError: String?
    var storageEvidenceGeneration = 0
    var storageEvidenceTask: Task<Void, Never>?
    /// Titles for sessions a screen has shown, keyed by source path.
    /// Display only -- no judgment reads these.
    @Published var sessionTitles: [String: SessionTitle] = [:]
    /// Sources already asked for, so a scrolling list does not re-request
    /// the same rows every time it redraws.
    var titleRequests: Set<String> = []
    var sessionTitleRequestTokens: [String: UUID] = [:]
    var candidateTitleRequestTokens: [String: UUID] = [:]
    /// Which project the Work screen has selected, and which session
    /// inside it. Selection, not navigation: the panes are always there.
    @Published var selectedProjectID: String?
    @Published var selectedSessionSource: String?
    /// A body-search hit may have been created after the metadata index was
    /// loaded. Keep the selected hit itself so the detail pane does not need
    /// to find it again in an older snapshot.
    @Published var selectedSearchMatch: SessionSearchMatch?
    /// The project whose retirement sheet is open. Retirement is an action
    /// on a project, not a place in the sidebar.
    @Published var retirementReview: RetirementReviewTarget?
    @Published var archiveInspectionFailures = 0
    @Published var archiveLoading = false
    /// Repository inspection and continuity binding are automatic Work-screen
    /// loaders too. Binding may scan every local session for up to 15 minutes,
    /// so it must share the screen's cancellation and stale-result contract.
    var archiveGeneration = 0
    var archiveTask: Task<Void, Never>?
    var archiveBindingComplete = false
    /// Raw backup/verify/restore is model-owned so Cmd-Q can cancel the
    /// subprocess and wait for its exact-inode cleanup before the host exits.
    var sessionBackupGeneration = 0
    var sessionBackupTask: Task<Void, Never>?
    /// Masked exports share one model-owned lease across every UI entry point.
    var sessionExportGeneration = 0
    var sessionExportTask: Task<Void, Never>?
    @Published var pendingLoginItemRemoval: PendingLoginItemRemoval?
    @Published var loginItemActionInFlight: String?
    var loginItemActionTask: Task<Void, Never>?
    @Published var archiveError: String?
    @Published var observationResult: ObservationResult?
    @Published var observationInFlight = false
    @Published var observationErrorMessage: String?
    /// Invalidates a cancelled Activity-screen observation so its late
    /// completion cannot overwrite a newer run or clear the newer spinner.
    var observationGeneration = 0
    @Published var timeQuotaCardState: TimeQuotaCardState?

    let logStore = ScanLogStore()
    let projectRoot: URL
    let scanRunner: ScanRunner
    let existingResultsLoader: ExistingResultsLoader
    let storageWatchEvidenceLoader: StorageWatchEvidenceLoader
    let cleanupExecution: CleanupExecutionClient
    let cleanupMutationRecorder: CleanupMutationRecorder
    var cleanupRequest: CleanupExecutionRequest?
    private let normalReportName = "검사결과.html"
    private let shareReportName = "검사결과_공유용.html"
    private let terminationSafetyGate = AppTerminationSafetyGate()
    /// Retained so application termination can cancel the scan and await the
    /// LocalProcessRunner cancellation handler before the host process exits.
    var scanTask: Task<Void, Never>?
    /// Invalidates output and post-processing from a cancelled scan before its
    /// subprocess has finished bounded process-group cleanup.
    var scanGeneration = 0
    private var liveStateTask: Task<Void, Never>?
    var applicationTerminationWaitGeneration = 0
    var applicationTerminationWaitTask: Task<Void, Never>?
    var applicationTerminationDeadlineTask: Task<Void, Never>?
    /// One-way latch: after Cmd-Q begins, delayed UI/init tasks may finish
    /// cleanup but cannot start a fresh scan or subprocess outside the captured
    /// termination wait set.
    var applicationTerminationStarted = false
    private var initialResultsLoaded = false
    private var lastScanAttemptAt: Date?
    var cleanupTask: Task<Void, Never>?
    var browserAutomationStopTask: Task<Void, Never>?
    /// Short-lived UI helpers used to start unstructured tasks. Registering
    /// their handles here gives screen navigation and Cmd-Q one place to
    /// cancel and await every subprocess they may own.
    var trackedApplicationTasks: [UUID: TrackedApplicationTask] = [:]
    /// Screen navigation cancels work immediately, but LocalProcessRunner's
    /// TERM-to-KILL escalation still needs an in-process owner for a bounded
    /// grace period. Keep those cancelled handles until they actually finish;
    /// Cmd-Q can then fold them back into its awaited snapshot.
    var pendingDrainTasks: [UUID: Task<Void, Never>] = [:]

    /// Deep evidence is deliberately much slower-moving than the five-second
    /// live free-space signal. Re-entering the app must not turn one current
    /// number into a full CPU/network/security/storage collection every 30 minutes.
    nonisolated static let deepScanFreshnessInterval: TimeInterval = 6 * 60 * 60
    nonisolated static let automaticScanRetryInterval: TimeInterval = 5 * 60
    nonisolated static let liveFreeSpaceRefreshInterval: UInt64 = 5_000_000_000

    init(
        automaticallyScansStaleResults: Bool = true,
        projectRoot: URL? = nil,
        scanRunner: @escaping ScanRunner = { projectRoot, onOutput in
            await ScanPipeline.run(projectRoot: projectRoot, onOutput: onOutput)
        },
        existingResultsLoader: @escaping ExistingResultsLoader = { projectRoot in
            await Task.detached(priority: .utility) {
                ScanResultLoader.load(projectRoot: projectRoot)
            }.value
        },
        storageWatchEvidenceLoader: @escaping StorageWatchEvidenceLoader = {
            await Task.detached(priority: .utility) {
                StorageWatchEvidenceStore.load()
            }.value
        },
        cleanupExecution: CleanupExecutionClient = .live,
        cleanupMutationRecorder: @escaping CleanupMutationRecorder = {
            ScanPublication.markCleanupMutationPending(in: $0)
        }
    ) {
        self.projectRoot = projectRoot ?? Self.detectProjectRoot()
        self.scanRunner = scanRunner
        self.existingResultsLoader = existingResultsLoader
        self.storageWatchEvidenceLoader = storageWatchEvidenceLoader
        self.cleanupExecution = cleanupExecution
        self.cleanupMutationRecorder = cleanupMutationRecorder
        self.cleanupMutationPending = ScanPublication.cleanupMutationIsPending(
            in: self.projectRoot
        )
        self.virusTotalEnabled = Self.loadVirusTotalEnabled(projectRoot: self.projectRoot)
        let keepState = SimulatorKeepStore.load()
        self.simulatorKeepUUIDs = keepState.uuids
        self.simulatorLegacyKeepEntries = keepState.legacyEntries
        startTrackedApplicationTask { [weak self] in
            guard let self else { return }
            await refreshExistingResults()
            initialResultsLoaded = true
            if automaticallyScansStaleResults {
                runAutomaticScanIfNeeded()
            }
        }
        startTrackedApplicationTask { [weak self] in
            await self?.refreshStorageWatchStatus()
        }
    }

    var isRunning: Bool { state == .running }
    var isBusy: Bool {
        isRunning
            || cleanupInFlight
            || browserAutomationStopInFlight
            || storageWatchInFlight
            || loginItemActionInFlight != nil
            // An observation measures what this Mac is doing on its own. A
            // scan or cleanup started underneath it lands in its own results
            // -- the scanner's du/lsof become the top "real CPU use" rows and
            // VirusTotal lookups appear as new connections -- so the window
            // would report the app's own work as the finding.
            || observationInFlight
            || resultLoading
    }
    var logText: String { logStore.text }
    var content: DeepScanSnapshot { deepScanSnapshot }
    var summary: ScanSummary? { content.summary }
    var collectionCoverage: CollectionCoverage? { content.collectionCoverage }
    var collectionIsIncomplete: Bool { collectionCoverage?.complete == false }
    var macOSSecurity: MacOSSecurityStatus? { content.macOSSecurity }
    var storage: StorageSnapshot? { content.storage }
    var currentFreeGB: Double? {
        liveState.freeSpace?.value.freeGB ?? storage?.freeGB
    }
    var findings: [ScanFinding] { content.findings }
    var securityFindings: [ScanFinding] { content.securityAttentionFindings }
    var storageAttentionFindings: [ScanFinding] { content.storageAttentionFindings }
    var cpuRows: [CpuRow] { content.cpuRows }
    var backgroundCpuRows: [BackgroundCpuRow] { content.backgroundCpuRows }
    var networkRows: [NetworkRow] { content.networkRows }
    var listeningPortRows: [ListeningPortRow] { content.listeningPortRows }
    var autorunRows: [AutorunRow] { content.autorunRows }
    var recentInstalls: [RecentInstallRow] { content.recentInstalls }
    var privacyPermissionRows: [PrivacyPermissionRow] { content.privacyPermissionRows }
    var devtoolUpdateRows: [DevtoolUpdateRow] { content.devtoolUpdateRows }
    var truncatedSecuritySections: [String] { content.truncatedSections }
    var attentionCpuRows: [CpuRow] { cpuRows.filter(\.requiresAttention) }
    var attentionBackgroundCpuRows: [BackgroundCpuRow] {
        backgroundCpuRows.filter(\.requiresAttention)
    }
    /// Rows whose work cannot be stopped by quitting the application they appear
    /// to belong to. These are the ones a process list alone misattributes.
    var detachedBackgroundCpuRows: [BackgroundCpuRow] {
        backgroundCpuRows.filter(\.isDetachedFromAnApp)
    }
    var attentionNetworkRows: [NetworkRow] { networkRows.filter(\.requiresAttention) }
    var attentionListeningPortRows: [ListeningPortRow] {
        listeningPortRows.filter(\.requiresAttention)
    }
    var securityFindingCount: Int { content.securityAttentionCount }
    var securityAttentionCount: Int {
        securityFindingCount + (collectionCoverage?.requiredIssues.count ?? 0)
    }
    var securityHasDanger: Bool { content.securityHasDanger }
    var normalReportURL: URL { projectRoot.appendingPathComponent(normalReportName) }
    var shareReportURL: URL { projectRoot.appendingPathComponent(shareReportName) }
    var hasNormalReport: Bool { reportURLIsSafe(normalReportURL) }
    var hasShareReport: Bool { reportURLIsSafe(shareReportURL) }
    var hasAnyReport: Bool { hasNormalReport || hasShareReport }

    func reportURLIsSafe(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL
        guard candidate == normalReportURL.standardizedFileURL
                || candidate == shareReportURL.standardizedFileURL else {
            return false
        }
        return Self.isSecureRegularFile(at: candidate, allowsRootOwner: false)
    }
    var newerStorageHistoryEntry: StorageHistoryEntry? {
        StorageHistoryStore.newestEntry(after: displayedStorageEntry, in: storageHistory)
    }
    var hasNewerStorageHistory: Bool { newerStorageHistoryEntry != nil }
    var hasUnresolvedSimulatorKeepEntries: Bool { !simulatorLegacyKeepEntries.isEmpty }
    var terminationSafetyState: AppTerminationSafetyState { terminationSafetyGate.state }
    var deepScanSnapshotIsStale: Bool {
        isDeepScanSnapshotStale(at: Date())
    }
    func isDeepScanSnapshotStale(at date: Date) -> Bool {
        guard let deepScanAt else { return true }
        let age = date.timeIntervalSince(deepScanAt)
        // A timestamp meaningfully in the future is untrustworthy — a timezone
        // change between scan and view can reinterpret the zone-less scan time
        // hours ahead — so treat it as stale instead of reporting "방금 검사".
        return age >= Self.deepScanFreshnessInterval || age < -60
    }
    func deepScanSnapshotNeedsRefresh(at date: Date = Date()) -> Bool {
        cleanupMutationPending
            || isDeepScanSnapshotStale(at: date)
            || hasNewerStorageHistory
    }
    var deepScanSnapshotAgeText: String {
        guard let deepScanAt else { return "검사 기록 없음" }
        let raw = Date().timeIntervalSince(deepScanAt)
        if raw < -60 { return "검사 시각 확인 필요" }
        let seconds = max(0, raw)
        if seconds < 60 { return "방금 검사" }
        if seconds < 3600 { return "\(Int(seconds / 60))분 전 검사" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))시간 전 검사" }
        return deepScanAt.formatted(date: .abbreviated, time: .shortened)
    }

    func runScan(preservingUserDiagnostics: Bool = false) {
        startScan(
            at: Date(),
            preservingUserDiagnostics: preservingUserDiagnostics
        )
    }

    func setApplicationActive(_ active: Bool) {
        if active && !applicationTerminationStarted {
            startLiveStateUpdates()
            runAutomaticScanIfNeeded()
        } else {
            liveStateTask?.cancel()
            liveStateTask = nil
        }
    }

    private func startLiveStateUpdates() {
        guard liveStateTask == nil else { return }
        liveStateTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshLiveState()
                do {
                    try await Task.sleep(nanoseconds: Self.liveFreeSpaceRefreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func refreshLiveState(at date: Date = Date()) async {
        let freeSpace = await Task.detached(priority: .utility) {
            LiveStateService.observeFreeSpace(observedAt: date)
        }.value
        liveState.recordFreeSpaceAttempt(freeSpace, attemptedAt: date)
    }

    func recordLiveFreeSpaceObservation(
        _ observation: Observation<LiveFreeSpace>,
        attemptedAt: Date = Date()
    ) {
        liveState.recordFreeSpaceAttempt(observation, attemptedAt: attemptedAt)
    }

    private func startScan(
        at date: Date,
        preservingUserDiagnostics: Bool = false
    ) {
        guard !applicationTerminationStarted, !isBusy else { return }
        scanGeneration &+= 1
        let generation = scanGeneration
        lastScanAttemptAt = date
        state = .running
        if !preservingUserDiagnostics {
            errorMessage = nil
            logStore.clear()
        }
        deepScanFailure = nil
        reportState = .unknown
        appendLog(
            preservingUserDiagnostics
                ? "정리 후 현재 상태를 다시 검사합니다."
                : "Modore 시작"
        )
        appendLog("프로젝트: \(projectRoot.path)")

        let root = projectRoot
        scanTask = Task {
            let result = await runScanRunner(root: root, generation: generation)
            guard scanCanPublish(generation: generation) else {
                finishCancelledScan()
                return
            }
            guard await finishRun(result: result, generation: generation) else {
                finishCancelledScan()
                return
            }
            scanTask = nil
        }
    }

    private func runScanRunner(root: URL, generation: Int) async -> ScanRunResult {
        let output = BoundedScanOutputBuffer()
        let runner = scanRunner
        return await withTaskCancellationHandler {
            await withTaskGroup(of: ScanRunResult.self) { group in
                group.addTask {
                    let result = await runner(root) { line in
                        output.send(line)
                    }
                    output.finish()
                    return result
                }

                for await _ in output.events {
                    guard scanCanPublish(generation: generation) else {
                        output.cancel()
                        group.cancelAll()
                        break
                    }
                    if let batch = output.takeBatch() {
                        let text = batch.text
                        if !text.isEmpty { appendLog(text) }
                    }
                }
                if !scanCanPublish(generation: generation) {
                    group.cancelAll()
                }
                let result = await group.next() ?? .scanFailed
                group.cancelAll()
                output.cancel()
                return result
            }
        } onCancel: {
            output.cancel()
        }
    }

    private func scanCanPublish(generation: Int) -> Bool {
        !Task.isCancelled
            && !applicationTerminationStarted
            && generation == scanGeneration
    }

    private func finishCancelledScan() {
        if !applicationTerminationStarted {
            state = .idle
            appendLog("검사를 취소했습니다.")
            AccessibilityAnnouncer.announce("검사를 취소했습니다")
        }
        scanTask = nil
    }

    /// The saved result remains visible while it is restored. Once restoration
    /// has finished, opening or returning to the app refreshes a missing or
    /// six-hour-old deep snapshot. A newer bounded storage observation can
    /// request reevaluation sooner; the five-second free-space value cannot.
    func runAutomaticScanIfNeeded(at date: Date = Date()) {
        guard Self.shouldRunAutomaticScan(
            initialResultsLoaded: initialResultsLoaded,
            isBusy: isBusy,
            lastDeepScanAt: deepScanAt,
            hasNewerStorageHistory: hasNewerStorageHistory,
            cleanupMutationPending: cleanupMutationPending,
            lastScanAttemptAt: lastScanAttemptAt,
            now: date
        ) else { return }

        startScan(at: date)
        guard isRunning else { return }
        appendLog("정밀 검사 결과가 없거나 6시간 이상 지났거나 새 저장공간 변화가 있어 자동 검사를 시작했습니다.")
    }

    nonisolated static func shouldRunAutomaticScan(
        initialResultsLoaded: Bool,
        isBusy: Bool,
        lastDeepScanAt: Date?,
        hasNewerStorageHistory: Bool,
        cleanupMutationPending: Bool = false,
        lastScanAttemptAt: Date?,
        now: Date
    ) -> Bool {
        guard initialResultsLoaded, !isBusy else { return false }
        if let lastScanAttemptAt {
            let attemptAge = now.timeIntervalSince(lastScanAttemptAt)
            if attemptAge >= -60, attemptAge < automaticScanRetryInterval {
                return false
            }
        }
        if cleanupMutationPending { return true }
        if hasNewerStorageHistory { return true }
        guard let lastDeepScanAt else { return true }
        let resultAge = now.timeIntervalSince(lastDeepScanAt)
        return resultAge >= deepScanFreshnessInterval || resultAge < -60
    }

    func cancelScan() {
        guard isRunning else { return }
        scanGeneration &+= 1
        scanTask?.cancel()
    }

    /// Cancels model-wide background work that is safe to interrupt and
    /// returns the captured handles so the application delegate can await
    /// subprocess cleanup. Destructive cleanup is deliberately excluded: its
    /// separate termination safety gate lets the transaction finish instead.
    func cancelNonDestructiveApplicationTaskHandles() -> [Task<Void, Never>] {
        var tasks = [scanTask, liveStateTask].compactMap { $0 }
        if scanTask != nil { scanGeneration &+= 1 }
        observationGeneration += 1
        observationInFlight = false
        tasks.append(contentsOf: cancelTrackedApplicationTasks())

        scanTask?.cancel()
        scanTask = nil
        if state == .running { state = .idle }

        liveStateTask?.cancel()
        liveStateTask = nil

        if !cleanupIsExecuting, let cleanupTask {
            tasks.append(cleanupTask)
            cleanupTask.cancel()
            self.cleanupTask = nil
            cleanupInFlight = false
        }

        if let browserAutomationStopTask {
            tasks.append(browserAutomationStopTask)
            browserAutomationStopTask.cancel()
            self.browserAutomationStopTask = nil
            browserAutomationStopInFlight = false
            browserAutomationStopIsExecuting = false
        }

        return tasks
    }

    /// Starts a task whose subprocess lifetime must not outlive the owning
    /// screen or application. The operation still runs when cancellation was
    /// already requested so its own `defer` cleanup can clear loading state.
    @discardableResult
    func startTrackedApplicationTask(
        scope: TrackedTaskScope = .application,
        operation: @escaping @MainActor () async -> Void
    ) -> UUID? {
        guard !applicationTerminationStarted else { return nil }
        let identifier = UUID()
        let task = Task<Void, Never> { @MainActor [weak self] in
            await operation()
            self?.trackedApplicationTasks[identifier] = nil
        }
        trackedApplicationTasks[identifier] = TrackedApplicationTask(
            scope: scope,
            task: task
        )
        return identifier
    }

    /// Removes matching handles from the registry before cancelling them so a
    /// completion racing on the main actor cannot be mistaken for new work.
    func cancelTrackedApplicationTasks(
        in scope: TrackedTaskScope? = nil
    ) -> [Task<Void, Never>] {
        let selected = trackedApplicationTasks.filter { _, tracked in
            scope == nil || tracked.scope == scope
        }
        // A screen-scoped cancellation keeps the entry until the task's own
        // completion removes it. Termination has captured strong handles in
        // its local wait set, so it may clear the dictionary atomically.
        if scope == nil {
            for identifier in selected.keys {
                trackedApplicationTasks[identifier] = nil
            }
        }
        let tasks = selected.values.map(\.task)
        for task in tasks { task.cancel() }
        return tasks
    }

    func retainPendingDrainTasks(_ tasks: [Task<Void, Never>]) {
        for task in tasks {
            let identifier = UUID()
            pendingDrainTasks[identifier] = task
            Task { @MainActor [weak self] in
                await task.value
                self?.pendingDrainTasks[identifier] = nil
            }
        }
    }

    /// A superseding request still owns the cancelled task until its process
    /// group has completed TERM/KILL cleanup. Preserve that handle so Cmd-Q
    /// can await it even after the public task slot points at the new request.
    func cancelAndRetainForDrain(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        retainPendingDrainTasks([task])
    }

    func takePendingDrainTasksForTermination() -> [Task<Void, Never>] {
        let tasks = Array(pendingDrainTasks.values)
        pendingDrainTasks.removeAll()
        return tasks
    }

    func cancelActivityScreenTasks() {
        observationGeneration += 1
        let tasks = cancelTrackedApplicationTasks(in: .activityScreen)
        retainPendingDrainTasks(tasks)
        observationInFlight = false
    }

    func cancelCleanupPreviewRequest() {
        guard cleanupInFlight, !cleanupIsExecuting else { return }
        cleanupTask?.cancel()
    }

    func beginDestructiveCleanupTransaction() {
        beginApplicationDestructiveTransaction()
        cleanupIsExecuting = true
    }

    func finishDestructiveCleanupTransaction() {
        cleanupIsExecuting = false
        finishApplicationDestructiveTransaction()
    }

    func beginApplicationDestructiveTransaction() {
        terminationSafetyGate.beginDestructiveTransaction()
    }

    func finishApplicationDestructiveTransaction() {
        terminationSafetyGate.finishDestructiveTransaction()
    }

    @discardableResult
    func deferApplicationTerminationUntilSafe(_ completion: @escaping () -> Void) -> Bool {
        terminationSafetyGate.deferTerminationUntilSafe(completion)
    }

    @discardableResult
    func finishRun(result: ScanRunResult, generation: Int) async -> Bool {
        guard scanCanPublish(generation: generation) else { return false }
        if result.scanSucceeded {
            guard await refreshExistingResults(forScanGeneration: generation),
                  scanCanPublish(generation: generation) else {
                return false
            }
            state = .finished
            cleanupMutationPending = ScanPublication.cleanupMutationIsPending(
                in: projectRoot
            )
            reportState = ReportState(runResult: result, attemptedAt: Date())
            if result.normalReport == .succeeded || result.shareReport == .succeeded {
                reportRevision += 1
            }
            if result.reportsSucceeded {
                appendLog("완료: 정밀 검사와 일반·공유용 리포트를 생성했습니다.")
            } else if let failureText = reportState.failureText {
                appendLog(failureText)
                markFailedReportAsPrevious(result)
            }
            let verdict = IncidentAssessment.make(
                content: content, storageChange: storageChange
            ).value
            AccessibilityAnnouncer.announce("정밀 검사 완료: \(verdict)")
        } else {
            state = .failed
            if selectedReportURL != nil {
                selectedReportTitle = "이전 리포트 (이번 검사 아님)"
            }
            deepScanFailure = DeepScanFailure(
                failedAt: Date(),
                detail: "표시된 이전 정밀 검사 결과를 현재 상태로 해석하지 마세요. 기록 화면에서 실패 단계를 확인할 수 있습니다."
            )
        }
        return true
    }

    @discardableResult
    func persistCleanupMutationIntent() -> Bool {
        if cleanupMutationPending,
           ScanPublication.cleanupMutationIsPending(in: projectRoot) {
            deepScanAt = nil
            return true
        }
        guard cleanupMutationRecorder(projectRoot) else {
            errorMessage = "정리 전 재검사 필요 상태를 디스크에 기록하지 못해 실행하지 않았습니다. 먼저 여유 공간을 확보한 뒤 다시 시도하세요."
            appendLog("정리 실행 중단: 재검사 필요 상태를 디스크에 기록하지 못함")
            return false
        }
        cleanupMutationPending = true
        deepScanAt = nil
        return true
    }

    private func markFailedReportAsPrevious(_ result: ScanRunResult) {
        guard let selectedReportURL else { return }
        if result.normalReport == .failed,
           selectedReportURL.standardizedFileURL == normalReportURL.standardizedFileURL {
            selectedReportTitle = "이전 일반 리포트 (이번 검사 아님)"
        } else if result.shareReport == .failed,
                  selectedReportURL.standardizedFileURL == shareReportURL.standardizedFileURL {
            selectedReportTitle = "이전 공유용 리포트 (이번 검사 아님)"
        }
    }

    @discardableResult
    private func refreshExistingResults(forScanGeneration generation: Int? = nil) async -> Bool {
        resultLoading = true
        defer { resultLoading = false }
        guard resultPublicationIsAllowed(forScanGeneration: generation) else { return false }
        let root = projectRoot
        let loaded = await existingResultsLoader(root)
        guard resultPublicationIsAllowed(forScanGeneration: generation) else { return false }
        storageWatchEvidenceGeneration &+= 1
        let evidenceGeneration = storageWatchEvidenceGeneration
        let evidence = await storageWatchEvidenceLoader()
        guard resultPublicationIsAllowed(forScanGeneration: generation) else { return false }

        deepScanSnapshot = loaded.content
        deepScanAt = loaded.deepScanAt
        if let completedScanVirusTotalEnabled = loaded.content.virusTotalEnabled {
            virusTotalEnabled = completedScanVirusTotalEnabled
        }
        reconcileLegacySimulatorKeepEntries(with: loaded.content.storage?.simulatorDevices ?? [])
        storageHistory = loaded.storageHistory
        displayedStorageEntry = loaded.displayedStorageEntry
        storageChange = loaded.storageChange
        freeSpaceSamples = loaded.freeSpaceSamples
        if evidenceGeneration == storageWatchEvidenceGeneration, let evidence {
            storageWatchPathEvents = evidence.pathEvents
            storageWatchSignalEvents = evidence.signalEvents
            storageWatchCommittedEvidenceAt = evidence.committedAt
        }
        if let diagnostic = loaded.diagnostic {
            appendLog(diagnostic)
        }
        if hasNormalReport {
            selectedReportURL = normalReportURL
            selectedReportTitle = "일반 리포트"
        } else if hasShareReport {
            selectedReportURL = shareReportURL
            selectedReportTitle = "공유용 리포트"
        }
        return true
    }

    private func resultPublicationIsAllowed(forScanGeneration generation: Int?) -> Bool {
        guard !Task.isCancelled, !applicationTerminationStarted else { return false }
        guard let generation else { return true }
        return generation == scanGeneration
    }

    func refreshStorageWatchEvidence() async {
        await refreshStorageWatchEvidence(using: storageWatchEvidenceLoader)
    }

    /// A later refresh owns publication even if an earlier filesystem read
    /// finishes afterward. An unstable or unreadable transaction preserves
    /// the last committed evidence already on screen.
    func refreshStorageWatchEvidence(
        using load: @escaping @Sendable () async -> StorageWatchEvidenceSnapshot?
    ) async {
        storageWatchEvidenceGeneration &+= 1
        let generation = storageWatchEvidenceGeneration
        let evidence = await load()
        guard generation == storageWatchEvidenceGeneration,
              let evidence else { return }
        storageWatchPathEvents = evidence.pathEvents
        storageWatchSignalEvents = evidence.signalEvents
        storageWatchCommittedEvidenceAt = evidence.committedAt
    }

    func appendLog(_ text: String) {
        logStore.append(text)
    }

    func replaceSimulatorKeepUUIDs(with uuids: Set<String>) {
        simulatorKeepUUIDs = uuids
    }

    private func reconcileLegacySimulatorKeepEntries(with devices: [SimulatorDevice]) {
        guard !simulatorLegacyKeepEntries.isEmpty else { return }
        let migration = SimulatorKeepState(
            uuids: simulatorKeepUUIDs,
            legacyEntries: simulatorLegacyKeepEntries
        ).resolvingLegacyEntries(with: devices)
        simulatorKeepUUIDs = migration.uuids

        guard migration.unresolvedEntries.isEmpty else {
            simulatorLegacyKeepEntries = migration.unresolvedEntries
            appendLog("기존 Simulator 보존 항목 \(migration.unresolvedEntries.count)개를 UUID로 확인하지 못해 모든 기기 삭제를 차단했습니다.")
            return
        }

        do {
            try SimulatorKeepStore.save(migration.uuids)
            simulatorLegacyKeepEntries = []
            appendLog("기존 Simulator 이름 보존 목록을 UUID 기준으로 안전하게 전환했습니다.")
        } catch {
            appendLog("기존 Simulator 보존 목록을 전환하지 못해 모든 기기 삭제를 차단했습니다: \(error.localizedDescription)")
        }
    }

    private func refreshStorageWatchStatus() async {
        let status = await StorageWatchService.status(projectRoot: projectRoot)
        storageWatchEnabled = status.enabled
        storageWatchDetail = status.detail
        storageWatchHealthState = status.healthState
        if let samples = status.freeSpaceSamples {
            freeSpaceSamples = samples
        }
    }

    private nonisolated static func isSecureRegularFile(
        at url: URL,
        allowsRootOwner: Bool
    ) -> Bool {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return Darwin.lstat(path, &value)
        }
        let allowedOwner = value.st_uid == Darwin.geteuid()
            || (allowsRootOwner && value.st_uid == 0)
        return status == 0
            && value.st_mode & S_IFMT == S_IFREG
            && allowedOwner
            && value.st_mode & mode_t(S_IWGRP | S_IWOTH) == 0
    }

    private nonisolated static func boundedRegularFileData(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        try SecureLocalFileIO.boundedRead(from: url, maximumBytes: maximumBytes)
    }

    private static func detectProjectRoot() -> URL {
        RuntimeWorkspace.resolve()
    }

    private static func loadVirusTotalEnabled(projectRoot: URL) -> Bool {
        let externalConfigURL = RuntimeWorkspace.userConfigURL()
        let configURL = FileManager.default.fileExists(atPath: externalConfigURL.path)
            ? externalConfigURL
            : projectRoot.appendingPathComponent("data/config.json")
        guard let data = try? boundedRegularFileData(
                at: configURL,
                maximumBytes: 1_048_576
              ),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vt = root["virustotal"] as? [String: Any] else {
            return false
        }
        let enabled = vt["enabled"] as? Bool ?? false
        let configuredKey = (vt["apiKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environmentKey = (ProcessInfo.processInfo.environment["VT_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = configuredKey.isEmpty ? environmentKey : configuredKey
        return enabled && !apiKey.isEmpty
    }
}
