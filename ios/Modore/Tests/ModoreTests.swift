import XCTest
@testable import Modore
import ModoreDomain
import Photos

private final class StubStorageReader: DeviceStorageReading {
    let values: DeviceStorageCapacityValues
    private(set) var requestedKeys: Set<URLResourceKey> = []
    private(set) var requestedURL: URL?

    init(values: DeviceStorageCapacityValues) {
        self.values = values
    }

    func capacityValues(
        at url: URL,
        forKeys keys: Set<URLResourceKey>
    ) throws -> DeviceStorageCapacityValues {
        requestedURL = url
        requestedKeys = keys
        return values
    }
}

private actor StubPhotoLibrary: PhotoLibraryAccessing {
    private let status: PhotoAuthorization
    private let requestedStatus: PhotoAuthorization
    private let summary: MediaSummary
    private var authorizationRequestCount = 0
    private var summaryScanCount = 0

    init(
        status: PhotoAuthorization,
        requestedStatus: PhotoAuthorization? = nil,
        summary: MediaSummary? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
        self.summary = summary ?? MediaSummary(
            videoCount: 0,
            videoDuration: 0,
            screenRecordingCount: 0,
            screenRecordingDuration: 0,
            longestVideos: [],
            authorization: status
        )
    }

    func authorizationStatus() async -> PhotoAuthorization {
        status
    }

    func requestAuthorization() async -> PhotoAuthorization {
        authorizationRequestCount += 1
        return requestedStatus
    }

    func summarizeVideoAssets(authorization: PhotoAuthorization) async -> MediaSummary {
        summaryScanCount += 1
        return summary
    }

    func callCounts() -> (authorizationRequests: Int, summaryScans: Int) {
        (authorizationRequestCount, summaryScanCount)
    }
}

private actor ControlledScanner: PhotoLibraryScanning {
    private var continuations: [CheckedContinuation<MediaSummary, Never>] = []
    private var scanCount = 0

    func requestAuthorization() async -> PhotoAuthorization {
        .authorized
    }

    func scan() async -> MediaSummary {
        scanCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForScanCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while scanCount < expected {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func currentScanCount() -> Int {
        scanCount
    }

    func completeScan(with summary: MediaSummary) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume(returning: summary)
        }
    }
}

private actor ViewLifetimeSuspensionGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForCount(_ expected: Int) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while continuations.count < expected {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}

private actor CancellationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private actor CancellationAwareScanner: PhotoLibraryScanning {
    private(set) var started = false
    private(set) var observedCancellation = false

    func requestAuthorization() async -> PhotoAuthorization {
        .authorized
    }

    func scan() async -> MediaSummary {
        started = true
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
            observedCancellation = Task.isCancelled
        }
        return MediaSummary(
            videoCount: 99,
            videoDuration: 99,
            screenRecordingCount: 0,
            screenRecordingDuration: 0,
            longestVideos: [],
            authorization: .authorized
        )
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<200 where !started {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return started
    }

    func waitUntilCancellationObserved() async -> Bool {
        for _ in 0..<200 where !observedCancellation {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return observedCancellation
    }
}

private actor ManualCancellationAwareScanner: PhotoLibraryScanning {
    private(set) var scanCount = 0
    private(set) var manualScanStarted = false
    private(set) var observedManualCancellation = false

    func requestAuthorization() async -> PhotoAuthorization { .authorized }

    func scan() async -> MediaSummary {
        scanCount += 1
        guard scanCount > 1 else { return .empty }
        manualScanStarted = true
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch {
            observedManualCancellation = Task.isCancelled
        }
        return MediaSummary(
            videoCount: 77,
            videoDuration: 77,
            screenRecordingCount: 0,
            screenRecordingDuration: 0,
            longestVideos: [],
            authorization: .authorized
        )
    }

    func waitUntilManualScanStarted() async -> Bool {
        for _ in 0..<200 where !manualScanStarted {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return manualScanStarted
    }

    func waitUntilFirstScanStarted() async -> Bool {
        for _ in 0..<200 where scanCount < 1 {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return scanCount >= 1
    }

    func waitUntilManualCancellationObserved() async -> Bool {
        for _ in 0..<200 where !observedManualCancellation {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return observedManualCancellation
    }
}

private final class BlockingPhotoLibraryWork: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func run() -> Bool {
        condition.lock()
        entered = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return Task.isCancelled
    }

    func waitUntilEntered() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(1)
        while !entered, condition.wait(until: deadline) {}
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private actor RecordingScanner: PhotoLibraryScanning {
    private let summary: MediaSummary
    private let requestedStatus: PhotoAuthorization
    private var requestCount = 0
    private var scanCount = 0
    private var events: [String] = []

    init(summary: MediaSummary, requestedStatus: PhotoAuthorization) {
        self.summary = summary
        self.requestedStatus = requestedStatus
    }

    func requestAuthorization() async -> PhotoAuthorization {
        requestCount += 1
        events.append("request")
        return requestedStatus
    }

    func scan() async -> MediaSummary {
        scanCount += 1
        events.append("scan")
        return summary
    }

    func callCounts() -> (requests: Int, scans: Int) {
        (requestCount, scanCount)
    }

    func recordedEvents() -> [String] {
        events
    }
}

private actor SuspendedAuthorizationScanner: PhotoLibraryScanning {
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private(set) var authorizationStarted = false
    private(set) var authorizationFinished = false
    private(set) var scanCount = 0

    func requestAuthorization() async -> PhotoAuthorization {
        authorizationStarted = true
        await withCheckedContinuation { continuation in
            authorizationContinuation = continuation
        }
        authorizationFinished = true
        return .authorized
    }

    func scan() async -> MediaSummary {
        scanCount += 1
        return .empty
    }

    func waitUntilAuthorizationStarted() async -> Bool {
        for _ in 0..<200 where !authorizationStarted {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return authorizationStarted
    }

    func releaseAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }

    func waitUntilAuthorizationFinished() async -> Bool {
        for _ in 0..<200 where !authorizationFinished {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return authorizationFinished
    }
}

final class ModoreTests: XCTestCase {
    func testStorageSnapshotCalculatesUsedAndGoalDeficit() {
        let snapshot = DeviceStorageSnapshot(totalBytes: 128_000_000_000, availableBytes: 12_500_000_000)
        XCTAssertEqual(snapshot.usedBytes, 115_500_000_000)
        XCTAssertEqual(snapshot.targetDeficitBytes, StorageRecoveryPolicy.defaultTargetAvailableBytes - 12_500_000_000)
    }

    func testStorageSnapshotDoesNotReportNegativeDeficit() {
        let snapshot = DeviceStorageSnapshot(
            totalBytes: 256_000_000_000,
            availableBytes: StorageRecoveryPolicy.defaultTargetAvailableBytes + 1
        )
        XCTAssertEqual(snapshot.targetDeficitBytes, 0)
    }

    func testCurrentStorageRequestsBothCapacityKeysAndPrefersImportantCapacity() {
        let reader = StubStorageReader(values: DeviceStorageCapacityValues(
            totalBytes: 1_000,
            importantAvailableBytes: 400,
            legacyAvailableBytes: 300
        ))
        let home = URL(fileURLWithPath: "/test-home")

        let snapshot = DeviceStorageSnapshot.current(reader: reader, homeDirectory: home)

        XCTAssertEqual(snapshot?.totalBytes, 1_000)
        XCTAssertEqual(snapshot?.availableBytes, 400)
        XCTAssertEqual(reader.requestedURL, home)
        XCTAssertEqual(reader.requestedKeys, [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey,
        ])
    }

    func testCurrentStorageFallsBackToRequestedLegacyCapacity() {
        let reader = StubStorageReader(values: DeviceStorageCapacityValues(
            totalBytes: 1_000,
            importantAvailableBytes: nil,
            legacyAvailableBytes: 275
        ))

        let snapshot = DeviceStorageSnapshot.current(reader: reader)

        XCTAssertEqual(snapshot?.availableBytes, 275)
    }

    func testByteFormattingUsesReadableDecimalUnits() {
        XCTAssertEqual(StorageFormatting.bytes(0), "0 B")
        XCTAssertEqual(
            StorageFormatting.bytes(1_610_612_736, locale: Locale(identifier: "en_US")),
            "1.5 GiB"
        )
        XCTAssertEqual(
            StorageFormatting.bytes(20 * StorageRecoveryPolicy.bytesPerGiB, locale: Locale(identifier: "en_US")),
            "20 GiB"
        )
    }

    func testDurationFormattingSummarizesHoursMinutesAndSeconds() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(DurationFormatting.string(0, locale: locale), "0s")
        XCTAssertEqual(DurationFormatting.string(65, locale: locale), "1m 5s")
        XCTAssertEqual(DurationFormatting.string(3661, locale: locale), "1h 1m")
    }

    func testMediaSummaryEmptyIsSafeBeforeAuthorization() {
        XCTAssertEqual(MediaSummary.empty.videoCount, 0)
        XCTAssertEqual(MediaSummary.empty.screenRecordingCount, 0)
        XCTAssertEqual(MediaSummary.empty.authorization, .notDetermined)
    }

    func testPhotoAuthorizationMapsEverySystemStatus() {
        XCTAssertEqual(PhotoAuthorization(.notDetermined), .notDetermined)
        XCTAssertEqual(PhotoAuthorization(.restricted), .restricted)
        XCTAssertEqual(PhotoAuthorization(.denied), .denied)
        XCTAssertEqual(PhotoAuthorization(.limited), .limited)
        XCTAssertEqual(PhotoAuthorization(.authorized), .authorized)
    }

    func testScannerDoesNotReadPhotoLibraryWithoutAuthorization() async {
        for status in [PhotoAuthorization.notDetermined, .restricted, .denied] {
            let library = StubPhotoLibrary(status: status)

            let summary = await PhotoLibraryScanner(library: library).scan()
            let counts = await library.callCounts()

            XCTAssertEqual(summary.authorization, status)
            XCTAssertEqual(summary.videoCount, 0)
            XCTAssertEqual(summary.longestVideos, [])
            XCTAssertEqual(counts.summaryScans, 0)
        }
    }

    func testAccumulatorAggregatesDurationsAndKeepsOnlyLongestFive() {
        let assets = [
            PhotoVideoAsset(id: "ten", duration: 10, createdAt: nil, isScreenRecording: false),
            PhotoVideoAsset(id: "three", duration: 3, createdAt: nil, isScreenRecording: true),
            PhotoVideoAsset(id: "negative", duration: -4, createdAt: nil, isScreenRecording: true),
            PhotoVideoAsset(id: "ninety-nine", duration: 99, createdAt: nil, isScreenRecording: false),
            PhotoVideoAsset(id: "tie-b", duration: 50, createdAt: nil, isScreenRecording: true),
            PhotoVideoAsset(id: "tie-a", duration: 50, createdAt: nil, isScreenRecording: false),
            PhotoVideoAsset(id: "twenty-five", duration: 25, createdAt: nil, isScreenRecording: false),
        ]
        for status in [PhotoAuthorization.limited, .authorized] {
            var accumulator = PhotoVideoSummaryAccumulator()
            for asset in assets { accumulator.consume(asset) }
            let summary = accumulator.summary(authorization: status)

            XCTAssertEqual(summary.authorization, status)
            XCTAssertEqual(summary.videoCount, 7)
            XCTAssertEqual(summary.videoDuration, 237)
            XCTAssertEqual(summary.screenRecordingCount, 3)
            XCTAssertEqual(summary.screenRecordingDuration, 53)
            XCTAssertEqual(
                summary.longestVideos.map(\.id),
                ["ninety-nine", "tie-a", "tie-b", "twenty-five", "ten"]
            )
            XCTAssertEqual(accumulator.retainedCandidateCount, 5)
        }
    }

    func testAccumulatorRetainsOnlyFiveCandidatesAcrossLargeStreamingInput() {
        var accumulator = PhotoVideoSummaryAccumulator()

        for index in 0..<100_000 {
            accumulator.consume(PhotoVideoAsset(
                id: String(format: "%06d", index),
                duration: TimeInterval(index),
                createdAt: nil,
                isScreenRecording: index.isMultiple(of: 10)
            ))
            if index.isMultiple(of: 10_000) {
                XCTAssertLessThanOrEqual(accumulator.retainedCandidateCount, 5)
            }
        }

        let summary = accumulator.summary(authorization: .authorized)
        XCTAssertEqual(summary.videoCount, 100_000)
        XCTAssertEqual(summary.longestVideos.map(\.id), [
            "099999", "099998", "099997", "099996", "099995",
        ])
        XCTAssertEqual(accumulator.retainedCandidateCount, 5)
    }

    func testAccumulatorStopsAtTheNextAssetAfterTaskCancellation() async {
        let gate = CancellationGate()
        let task = Task { () -> PhotoVideoSummaryAccumulator in
            var accumulator = PhotoVideoSummaryAccumulator()
            accumulator.consume(PhotoVideoAsset(
                id: "before-cancel",
                duration: 1,
                createdAt: nil,
                isScreenRecording: false
            ))
            await gate.wait()
            for index in 0..<100 {
                guard accumulator.consume(PhotoVideoAsset(
                    id: "after-\(index)",
                    duration: 1,
                    createdAt: nil,
                    isScreenRecording: false
                )) else { break }
            }
            return accumulator
        }
        for _ in 0..<200 {
            if await gate.entered { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let entered = await gate.entered
        XCTAssertTrue(entered)

        task.cancel()
        await gate.release()
        let accumulator = await task.value

        XCTAssertEqual(accumulator.videoCount, 1)
        XCTAssertEqual(accumulator.retainedCandidateCount, 1)
    }

    func testPhotoLibraryWorkerPropagatesCancellationToDetachedSynchronousWork() async {
        let work = BlockingPhotoLibraryWork()
        let task = Task {
            await PhotoLibraryWorker.run { work.run() }
        }
        XCTAssertTrue(work.waitUntilEntered())

        task.cancel()
        work.release()

        let cancellationReachedWorker = await task.value
        XCTAssertTrue(cancellationReachedWorker)
    }

    func testScannerReturnsAuthorizedLibrarySummary() async {
        let expected = MediaSummary(
            videoCount: 12,
            videoDuration: 90,
            screenRecordingCount: 3,
            screenRecordingDuration: 25,
            longestVideos: [],
            authorization: .limited
        )
        let library = StubPhotoLibrary(status: .limited, summary: expected)

        let summary = await PhotoLibraryScanner(library: library).scan()
        let counts = await library.callCounts()

        XCTAssertEqual(summary, expected)
        XCTAssertEqual(counts.summaryScans, 1)
    }

    @MainActor
    func testRefreshSuppressesConcurrentScanAndRestoresState() async {
        let firstSummary = MediaSummary(
            videoCount: 1,
            videoDuration: 20,
            screenRecordingCount: 0,
            screenRecordingDuration: 0,
            longestVideos: [],
            authorization: .authorized
        )
        let scanner = ControlledScanner()
        let expectedStorage = DeviceStorageSnapshot(totalBytes: 1_000, availableBytes: 250)
        let model = ModoreViewModel(
            scanner: scanner,
            storageSnapshot: { expectedStorage }
        )

        model.refresh()
        model.refresh()
        XCTAssertTrue(model.isScanning)
        XCTAssertEqual(model.storage, expectedStorage)

        let firstScanStarted = await scanner.waitForScanCount(1)
        XCTAssertTrue(firstScanStarted)
        let concurrentScanCount = await scanner.currentScanCount()
        XCTAssertEqual(concurrentScanCount, 1)
        await scanner.completeScan(with: firstSummary)
        await model.waitForCurrentOperation()

        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.media, firstSummary)

        model.refresh()
        let secondScanStarted = await scanner.waitForScanCount(2)
        XCTAssertTrue(secondScanStarted)
        let resumedScanCount = await scanner.currentScanCount()
        XCTAssertEqual(resumedScanCount, 2)
        await scanner.completeScan(with: firstSummary)
        await model.waitForCurrentOperation()
        XCTAssertFalse(model.isScanning)
    }

    @MainActor
    func testRequestPhotoAccessRequestsThenScansAndRestoresState() async {
        let summary = MediaSummary(
            videoCount: 2,
            videoDuration: 40,
            screenRecordingCount: 1,
            screenRecordingDuration: 25,
            longestVideos: [],
            authorization: .limited
        )
        let scanner = RecordingScanner(summary: summary, requestedStatus: .limited)
        let model = ModoreViewModel(scanner: scanner)

        model.requestPhotoAccess()
        XCTAssertTrue(model.isScanning)
        await model.waitForCurrentOperation()
        let counts = await scanner.callCounts()
        let events = await scanner.recordedEvents()

        XCTAssertEqual(counts.requests, 1)
        XCTAssertEqual(counts.scans, 1)
        XCTAssertEqual(events, ["request", "scan"])
        XCTAssertEqual(model.media, summary)
        XCTAssertEqual(model.authorization, .limited)
        XCTAssertFalse(model.isScanning)
    }

    @MainActor
    func testCancellationDuringAuthorizationPreventsPhotoScan() async {
        let scanner = SuspendedAuthorizationScanner()
        let model = ModoreViewModel(scanner: scanner)

        model.requestPhotoAccess()
        let authorizationStarted = await scanner.waitUntilAuthorizationStarted()
        XCTAssertTrue(authorizationStarted)
        XCTAssertTrue(model.isScanning)

        model.cancelCurrentOperation()
        await scanner.releaseAuthorization()
        let authorizationFinished = await scanner.waitUntilAuthorizationFinished()
        XCTAssertTrue(authorizationFinished)
        for _ in 0..<10 { await Task.yield() }

        let scanCount = await scanner.scanCount
        XCTAssertEqual(scanCount, 0)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.media, .empty)
    }

    @MainActor
    func testViewLifetimeCancellationStopsScanAndDoesNotPublishPartialSummary() async {
        let scanner = CancellationAwareScanner()
        let model = ModoreViewModel(scanner: scanner)
        let viewTask = Task { @MainActor in
            await model.refreshForViewLifetime()
        }

        let started = await scanner.waitUntilStarted()
        XCTAssertTrue(started)
        XCTAssertTrue(model.isScanning)

        viewTask.cancel()
        await viewTask.value
        let observedCancellation = await scanner.waitUntilCancellationObserved()

        XCTAssertTrue(observedCancellation)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.media, .empty)
    }

    @MainActor
    func testViewLifetimeCancellationAlsoStopsALaterManualScan() async {
        let scanner = ManualCancellationAwareScanner()
        let model = ModoreViewModel(scanner: scanner)
        let viewTask = Task { @MainActor in
            await model.refreshForViewLifetime()
        }
        let firstScanStarted = await scanner.waitUntilFirstScanStarted()
        XCTAssertTrue(firstScanStarted)
        await model.waitForCurrentOperation()
        let firstScanCount = await scanner.scanCount
        XCTAssertEqual(firstScanCount, 1)

        model.refresh()
        let started = await scanner.waitUntilManualScanStarted()
        XCTAssertTrue(started)
        XCTAssertTrue(model.isScanning)

        viewTask.cancel()
        await viewTask.value
        let observedCancellation = await scanner.waitUntilManualCancellationObserved()

        XCTAssertTrue(observedCancellation)
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.media, .empty)
    }

    @MainActor
    func testOlderViewLifetimeCannotCancelNewLifetimeScan() async {
        let firstSummary = MediaSummary.empty
        let secondSummary = MediaSummary(
            videoCount: 4,
            videoDuration: 80,
            screenRecordingCount: 1,
            screenRecordingDuration: 20,
            longestVideos: [],
            authorization: .authorized
        )
        let scanner = ControlledScanner()
        let lifetimeGate = ViewLifetimeSuspensionGate()
        let model = ModoreViewModel(
            scanner: scanner,
            viewLifetimeSuspension: { await lifetimeGate.wait() }
        )

        let olderLifetime = Task { @MainActor in
            await model.refreshForViewLifetime()
        }
        let firstScanStarted = await scanner.waitForScanCount(1)
        let olderLifetimeEntered = await lifetimeGate.waitForCount(1)
        XCTAssertTrue(firstScanStarted)
        XCTAssertTrue(olderLifetimeEntered)
        await scanner.completeScan(with: firstSummary)
        await model.waitForCurrentOperation()

        olderLifetime.cancel()
        let newerLifetime = Task { @MainActor in
            await model.refreshForViewLifetime()
        }
        let secondScanStarted = await scanner.waitForScanCount(2)
        let newerLifetimeEntered = await lifetimeGate.waitForCount(2)
        XCTAssertTrue(secondScanStarted)
        XCTAssertTrue(newerLifetimeEntered)
        XCTAssertTrue(model.isScanning)

        await lifetimeGate.releaseNext()
        await olderLifetime.value

        XCTAssertTrue(model.isScanning)
        await scanner.completeScan(with: secondSummary)
        await model.waitForCurrentOperation()
        XCTAssertEqual(model.media, secondSummary)

        newerLifetime.cancel()
        await lifetimeGate.releaseNext()
        await newerLifetime.value
        XCTAssertFalse(model.isScanning)
    }
}
