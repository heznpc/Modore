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
    private let assets: [PhotoVideoAsset]
    private var authorizationRequestCount = 0
    private var assetFetchCount = 0

    init(
        status: PhotoAuthorization,
        requestedStatus: PhotoAuthorization? = nil,
        assets: [PhotoVideoAsset] = []
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
        self.assets = assets
    }

    func authorizationStatus() async -> PhotoAuthorization {
        status
    }

    func requestAuthorization() async -> PhotoAuthorization {
        authorizationRequestCount += 1
        return requestedStatus
    }

    func fetchVideoAssets() async -> [PhotoVideoAsset] {
        assetFetchCount += 1
        return assets
    }

    func callCounts() -> (authorizationRequests: Int, assetFetches: Int) {
        (authorizationRequestCount, assetFetchCount)
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

private actor RecordingScanner: PhotoLibraryScanning {
    private let summary: MediaSummary
    private let requestedStatus: PhotoAuthorization
    private var requestCount = 0
    private var scanCount = 0

    init(summary: MediaSummary, requestedStatus: PhotoAuthorization) {
        self.summary = summary
        self.requestedStatus = requestedStatus
    }

    func requestAuthorization() async -> PhotoAuthorization {
        requestCount += 1
        return requestedStatus
    }

    func scan() async -> MediaSummary {
        scanCount += 1
        return summary
    }

    func callCounts() -> (requests: Int, scans: Int) {
        (requestCount, scanCount)
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

    func testScannerDoesNotFetchAssetsWithoutAuthorization() async {
        for status in [PhotoAuthorization.notDetermined, .restricted, .denied] {
            let library = StubPhotoLibrary(
                status: status,
                assets: [PhotoVideoAsset(
                    id: "must-not-be-read",
                    duration: 10,
                    createdAt: nil,
                    isScreenRecording: false
                )]
            )

            let summary = await PhotoLibraryScanner(library: library).scan()
            let counts = await library.callCounts()

            XCTAssertEqual(summary.authorization, status)
            XCTAssertEqual(summary.videoCount, 0)
            XCTAssertEqual(summary.longestVideos, [])
            XCTAssertEqual(counts.assetFetches, 0)
        }
    }

    func testScannerAggregatesDurationsAndKeepsOnlyLongestFiveForReadableAuthorization() async {
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
            let library = StubPhotoLibrary(status: status, assets: assets)

            let summary = await PhotoLibraryScanner(library: library).scan()

            XCTAssertEqual(summary.authorization, status)
            XCTAssertEqual(summary.videoCount, 7)
            XCTAssertEqual(summary.videoDuration, 237)
            XCTAssertEqual(summary.screenRecordingCount, 3)
            XCTAssertEqual(summary.screenRecordingDuration, 53)
            XCTAssertEqual(
                summary.longestVideos.map(\.id),
                ["ninety-nine", "tie-a", "tie-b", "twenty-five", "ten"]
            )
        }
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

        XCTAssertEqual(counts.requests, 1)
        XCTAssertEqual(counts.scans, 1)
        XCTAssertEqual(model.media, summary)
        XCTAssertEqual(model.authorization, .limited)
        XCTAssertFalse(model.isScanning)
    }
}
