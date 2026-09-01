import Foundation
import XCTest
@testable import Modore

final class StorageWatchSnapshotTests: XCTestCase {
    func testLoadsValidatedRowsAndGroupsOneDropEvent() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage-watch-paths.tsv")
        let text = """
        2026-07-12T01:00:00Z\t2097152\tok\tCodex 로컬 데이터\t/Users/test/.codex
        2026-07-12T01:00:00Z\t1048576\ttimed_out\t사용자 캐시\t/Users/test/Library/Caches
        2026-07-12T01:00:00Z\t1\tunknown\t무시\t/Users/test/ignored
        2026-07-12T01:00:00Z\t1\tok\t상대 경로\trelative/path
        """
        try writePrivate(text, to: url)

        let snapshots = StorageWatchSnapshotStore.load(from: url)
        XCTAssertEqual(snapshots.count, 2)
        XCTAssertEqual(snapshots[0].label, "Codex 로컬 데이터")
        XCTAssertEqual(snapshots[0].sizeGB, 2, accuracy: 0.001)
        XCTAssertFalse(snapshots[1].measured)

        let events = StorageWatchSnapshotStore.events(from: snapshots)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rows.map(\.label), ["Codex 로컬 데이터", "사용자 캐시"])
    }

    func testBoundsLoadedRowsToLocalHistoryLimit() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage-watch-paths.tsv")
        let rows = (0..<(StorageWatchSnapshotStore.maximumRows + 10)).map { index in
            "2026-07-12T01:00:00Z\t\(index)\tok\trow-\(index)\t/tmp/row-\(index)"
        }
        try writePrivate(rows.joined(separator: "\n") + "\n", to: url)

        let snapshots = StorageWatchSnapshotStore.load(from: url)
        XCTAssertEqual(snapshots.count, StorageWatchSnapshotStore.maximumRows)
        XCTAssertFalse(snapshots.contains { $0.label == "row-0" })
        XCTAssertTrue(snapshots.contains { $0.label == "row-\(rows.count - 1)" })
    }

    func testLoadsValidatedSwapAndProcessSignals() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage-watch-signals.tsv")
        let text = """
        2026-08-31T12:00:00Z\tswap\t3145728\t4194304\t0\tok\tmacOS 스왑\t/private/var/vm
        2026-08-31T12:00:00Z\tprocess_rss\t800000\t0\t42\tok\tCodex Renderer\tCodex Renderer
        2026-08-31T12:00:00Z\tswap\t5000000\t4194304\t0\tok\tinvalid\t/private/var/vm
        2026-08-31T12:00:00Z\tprocess_rss\t1\t0\t0\tok\tinvalid\t/usr/bin/false
        2026-08-31T12:00:00Z\tcommand\t1\t0\t1\tok\tinvalid\t/usr/bin/false
        """
        try writePrivate(text, to: url)

        let signals = StorageWatchSignalStore.load(from: url)
        XCTAssertEqual(signals.count, 2)
        XCTAssertEqual(signals[0].kind, .swap)
        XCTAssertEqual(signals[0].valueKB, 3_145_728)
        XCTAssertEqual(signals[1].kind, .processRSS)
        XCTAssertEqual(signals[1].pid, 42)

        let events = StorageWatchSignalStore.events(from: signals)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].rows.map(\.kind), [.swap, .processRSS])
    }

    func testBoundsLoadedSignalRows() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage-watch-signals.tsv")
        let rows = (1...(StorageWatchSignalStore.maximumRows + 10)).map { index in
            "2026-08-31T12:00:00Z\tprocess_rss\t\(index)\t0\t\(index)\tok\tprocess-\(index)\tprocess-\(index)"
        }
        try writePrivate(rows.joined(separator: "\n") + "\n", to: url)

        let signals = StorageWatchSignalStore.load(from: url)
        XCTAssertEqual(signals.count, StorageWatchSignalStore.maximumRows)
        XCTAssertFalse(signals.contains { $0.pid == 1 })
        XCTAssertTrue(signals.contains { $0.pid == rows.count })
    }

    func testLatestEvidenceNeverMixesDifferentCaptureTimes() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let pathEvent = StorageWatchPathEvent(capturedAt: newer, rows: [])
        let signalEvent = StorageWatchSignalEvent(capturedAt: older, rows: [])

        let evidence = StorageWatchEvidenceEvent.latest(
            pathEvents: [pathEvent],
            signalEvents: [signalEvent],
            committedAt: newer
        )

        XCTAssertEqual(evidence?.capturedAt, newer)
        XCTAssertEqual(evidence?.pathEvent, pathEvent)
        XCTAssertNil(evidence?.signalEvent)
    }

    func testLatestEvidenceJoinsSignalsAndPathsFromOneCapture() {
        let capturedAt = Date(timeIntervalSince1970: 200)
        let pathEvent = StorageWatchPathEvent(capturedAt: capturedAt, rows: [])
        let signalEvent = StorageWatchSignalEvent(capturedAt: capturedAt, rows: [])

        let evidence = StorageWatchEvidenceEvent.latest(
            pathEvents: [pathEvent],
            signalEvents: [signalEvent],
            committedAt: capturedAt
        )

        XCTAssertEqual(evidence?.pathEvent, pathEvent)
        XCTAssertEqual(evidence?.signalEvent, signalEvent)
    }

    func testCommittedEvidenceIgnoresANewerInFlightEvent() {
        let committedAt = Date(timeIntervalSince1970: 100)
        let inFlightAt = Date(timeIntervalSince1970: 200)
        let committedPath = StorageWatchPathEvent(capturedAt: committedAt, rows: [])
        let inFlightSignal = StorageWatchSignalEvent(capturedAt: inFlightAt, rows: [])

        let evidence = StorageWatchEvidenceEvent.latest(
            pathEvents: [committedPath],
            signalEvents: [inFlightSignal],
            committedAt: committedAt
        )

        XCTAssertEqual(evidence?.capturedAt, committedAt)
        XCTAssertEqual(evidence?.pathEvent, committedPath)
        XCTAssertNil(evidence?.signalEvent)
    }

    func testLoadsCommittedEvidencePointerFromWatcherState() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("storage-watch.tsv")
        try writePrivate(
            "version\t1\nlastEvidenceAt\t2026-08-31T16:03:05.099095Z\n",
            to: url
        )

        let committedAt = StorageWatchEvidenceCommitStore.load(from: url)

        XCTAssertNotNil(committedAt)
        XCTAssertEqual(
            committedAt?.timeIntervalSince1970 ?? 0,
            1_788_192_185.099095,
            accuracy: 0.001
        )
    }

    func testStableEvidenceReadDropsUncommittedTail() {
        let committedAt = Date(timeIntervalSince1970: 100)
        let inFlightAt = Date(timeIntervalSince1970: 200)
        let evidence = StorageWatchEvidenceStore.loadStable(
            readCommittedAt: { committedAt },
            readPaths: {
                [
                    pathSnapshot(at: committedAt, label: "committed"),
                    pathSnapshot(at: inFlightAt, label: "in-flight"),
                ]
            },
            readSignals: {
                [
                    signalSnapshot(at: committedAt, pid: 10, label: "committed"),
                    signalSnapshot(at: inFlightAt, pid: 20, label: "in-flight"),
                ]
            }
        )

        XCTAssertEqual(evidence?.committedAt, committedAt)
        XCTAssertEqual(evidence?.pathEvents.flatMap(\.rows).map(\.label), ["committed"])
        XCTAssertEqual(evidence?.signalEvents.flatMap(\.rows).map(\.label), ["committed"])
    }

    func testStableEvidenceReadRetriesPointerChange() {
        let first = Date(timeIntervalSince1970: 100)
        let newest = Date(timeIntervalSince1970: 200)
        var pointerReads = [first, newest, newest, newest]
        var pathReads = 0
        let evidence = StorageWatchEvidenceStore.loadStable(
            readCommittedAt: { pointerReads.removeFirst() },
            readPaths: {
                pathReads += 1
                return [
                    pathSnapshot(at: first, label: "first"),
                    pathSnapshot(at: newest, label: "newest"),
                ]
            },
            readSignals: { [] }
        )

        XCTAssertEqual(pathReads, 2)
        XCTAssertEqual(evidence?.committedAt, newest)
        XCTAssertEqual(evidence?.pathEvents.flatMap(\.rows).map(\.label), ["newest"])
    }

    func testStableEvidenceReadIsBoundedWhenPointerNeverStabilizes() {
        var pointerReads = 0
        var pathReads = 0
        let evidence = StorageWatchEvidenceStore.loadStable(
            maximumAttempts: Int.max,
            readCommittedAt: {
                defer { pointerReads += 1 }
                return Date(timeIntervalSince1970: TimeInterval(pointerReads))
            },
            readPaths: {
                pathReads += 1
                return [pathSnapshot(at: Date(timeIntervalSince1970: 1), label: "row")]
            },
            readSignals: { [] }
        )

        XCTAssertNil(evidence)
        XCTAssertEqual(pathReads, StorageWatchEvidenceStore.maximumReadAttempts)
        XCTAssertEqual(pointerReads, StorageWatchEvidenceStore.maximumReadAttempts * 2)
    }

    func testStableEvidenceReadRejectsNilPointerAndReadFailure() {
        XCTAssertNil(StorageWatchEvidenceStore.loadStable(
            readCommittedAt: { nil },
            readPaths: { [pathSnapshot(at: Date(), label: "row")] },
            readSignals: { [] }
        ))

        let committedAt = Date(timeIntervalSince1970: 100)
        XCTAssertNil(StorageWatchEvidenceStore.loadStable(
            readCommittedAt: { committedAt },
            readPaths: { nil },
            readSignals: { [] }
        ))
        XCTAssertNil(StorageWatchEvidenceStore.loadStable(
            readCommittedAt: { committedAt },
            readPaths: { [pathSnapshot(at: committedAt, label: "row")] },
            readSignals: { nil }
        ))
    }

    // MARK: - StorageWatchService.healthState

    func testHealthStateWithNoHeartbeatFileIsNeverAttempted() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: nil
        )
        XCTAssertEqual(state, .neverAttempted)
    }

    func testHealthStateWithHeartbeatMissingLastAttemptAtIsNeverAttempted() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate("someOtherField\tvalue\n", to: heartbeatURL)

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: nil
        )
        XCTAssertEqual(state, .neverAttempted)
    }

    func testHealthStateWithAttemptButNoSuccessEverIsAttemptedThenFailed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate("lastAttemptAt\t2026-08-12T01:00:00Z\n", to: heartbeatURL)

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: nil,
            now: Date(timeIntervalSince1970: 1_786_100_000)
        )
        XCTAssertEqual(state, .attemptedThenFailed)
    }

    func testHealthStateWithAttemptNewerThanSuccessIsAttemptedThenFailed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        // A fresh attempt fired but never (yet) produced a newer success --
        // either it's still running or it just crashed. Either way this must
        // not be reported as healthy just because an older success exists.
        try writePrivate(
            """
            lastAttemptAt\t2026-08-12T02:00:00Z
            """,
            to: heartbeatURL
        )
        let freshestSuccessAt = ISO8601DateFormatter().date(from: "2026-08-12T01:00:00Z")!

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: freshestSuccessAt,
            now: ISO8601DateFormatter().date(from: "2026-08-12T02:00:10Z")!
        )
        XCTAssertEqual(state, .attemptedThenFailed)
    }

    func testHealthStateWithRecentSuccessAfterAttemptIsRecentSuccess() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate(
            """
            lastAttemptAt\t2026-08-12T02:00:00Z
            lastExitCode\t0
            lastFinishedAt\t2026-08-12T02:00:05Z
            """,
            to: heartbeatURL
        )
        let freshestSuccessAt = ISO8601DateFormatter().date(from: "2026-08-12T02:00:05Z")!

        // 30 minutes after the success: well inside the 135-minute grace window.
        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: freshestSuccessAt,
            now: freshestSuccessAt.addingTimeInterval(30 * 60)
        )
        XCTAssertEqual(state, .recentSuccess)
    }

    func testHealthStateWithSuccessExactlyAtStalenessBoundaryIsRecentSuccess() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate("lastAttemptAt\t2026-08-12T02:00:00Z\n", to: heartbeatURL)
        let freshestSuccessAt = ISO8601DateFormatter().date(from: "2026-08-12T02:00:00Z")!

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: freshestSuccessAt,
            now: freshestSuccessAt.addingTimeInterval(StorageWatchService.heartbeatStalenessInterval)
        )
        XCTAssertEqual(state, .recentSuccess)
    }

    func testHealthStateWithOldSuccessAndNoNewerAttemptIsStaleSuccess() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        // The last attempt on record is the same run that produced the
        // success -- nothing has fired since, and it's long past the grace
        // window. This is "gone quiet," not "actively failing."
        try writePrivate(
            """
            lastAttemptAt\t2026-08-01T02:00:00Z
            lastExitCode\t0
            lastFinishedAt\t2026-08-01T02:00:05Z
            """,
            to: heartbeatURL
        )
        let freshestSuccessAt = ISO8601DateFormatter().date(from: "2026-08-01T02:00:05Z")!

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: freshestSuccessAt,
            now: freshestSuccessAt.addingTimeInterval(StorageWatchService.heartbeatStalenessInterval + 1)
        )
        XCTAssertEqual(state, .staleSuccess)
    }

    func testFutureSuccessCannotMaskTheCurrentFailedAttempt() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate(
            """
            lastAttemptAt\t2026-08-12T02:00:00Z
            """,
            to: heartbeatURL
        )

        let state = StorageWatchService.healthState(
            heartbeatURL: heartbeatURL,
            freshestSuccessAt: ISO8601DateFormatter().date(
                from: "2026-08-13T02:00:00Z"
            )!,
            now: ISO8601DateFormatter().date(from: "2026-08-12T02:01:00Z")!
        )

        XCTAssertEqual(state, .attemptedThenFailed)
    }

    func testMalformedCompletedHeartbeatFailsClosed() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        let success = ISO8601DateFormatter().date(from: "2026-08-12T02:00:05Z")!

        for heartbeat in [
            "lastAttemptAt\t2026-08-12T02:00:00Z\nlastExitCode\tbogus\nlastFinishedAt\t2026-08-12T02:00:05Z\n",
            "lastAttemptAt\t2026-08-12T02:00:00Z\nlastExitCode\t0\n",
            "lastAttemptAt\t2026-08-12T02:00:00Z\nlastFinishedAt\t2026-08-12T02:00:05Z\n",
        ] {
            try writePrivate(heartbeat, to: heartbeatURL)
            XCTAssertEqual(
                StorageWatchService.healthState(
                    heartbeatURL: heartbeatURL,
                    freshestSuccessAt: success,
                    now: success.addingTimeInterval(60)
                ),
                .attemptedThenFailed,
                heartbeat
            )
        }
    }

    func testExplicitFailedHeartbeatOutranksNearFutureAndEqualSuccessRows() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let heartbeatURL = directory.appendingPathComponent("storage-watch-heartbeat.tsv")
        try writePrivate(
            """
            lastAttemptAt\t2026-08-12T02:00:00Z
            lastExitCode\t1
            lastFinishedAt\t2026-08-12T02:00:05Z
            """,
            to: heartbeatURL
        )
        let now = ISO8601DateFormatter().date(from: "2026-08-12T02:00:30Z")!

        for successTimestamp in [
            "2026-08-12T02:00:00Z",
            "2026-08-12T02:01:00Z",
        ] {
            let state = StorageWatchService.healthState(
                heartbeatURL: heartbeatURL,
                freshestSuccessAt: ISO8601DateFormatter().date(from: successTimestamp)!,
                now: now
            )
            XCTAssertEqual(state, .attemptedThenFailed, successTimestamp)
        }
    }

    func testFreeSpaceSampleLoaderDropsFarFutureRowsBeforeSorting() throws {
        let directory = try makePrivateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampleURL = directory.appendingPathComponent("storage-samples.tsv")
        try writePrivate(
            """
            2026-08-12T02:00:00Z\t10485760\t0\tok
            2026-08-13T02:00:00Z\t9437184\t1048576\twarning
            """,
            to: sampleURL
        )

        let samples = StorageHistoryStore.loadFreeSpaceSamples(
            from: sampleURL,
            now: ISO8601DateFormatter().date(from: "2026-08-12T02:01:00Z")!
        )

        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples.first?.status, "ok")
        XCTAssertEqual(
            samples.first?.checkedAt,
            ISO8601DateFormatter().date(from: "2026-08-12T02:00:00Z")!
        )
    }

    private func makePrivateDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pch-watch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func writePrivate(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func pathSnapshot(
        at capturedAt: Date,
        label: String
    ) -> StorageWatchPathSnapshot {
        StorageWatchPathSnapshot(
            capturedAt: capturedAt,
            sizeGB: 1,
            status: "ok",
            label: label,
            path: "/tmp/\(label)"
        )
    }

    private func signalSnapshot(
        at capturedAt: Date,
        pid: Int,
        label: String
    ) -> StorageWatchSignalSnapshot {
        StorageWatchSignalSnapshot(
            capturedAt: capturedAt,
            kind: .processRSS,
            valueKB: 1,
            allocatedKB: 0,
            pid: pid,
            label: label,
            reference: label
        )
    }
}

private actor StorageWatchEvidenceReleaseGate {
    private var isOpen = false
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func hasEntered() -> Bool { entered }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
final class StorageWatchEvidenceRefreshTests: XCTestCase {
    func testUnstableRefreshPreservesExistingCommittedEvidence() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let committed = evidence(at: Date(timeIntervalSince1970: 100), label: "kept")

        await model.refreshStorageWatchEvidence { committed }
        await model.refreshStorageWatchEvidence { nil }

        XCTAssertEqual(model.storageWatchCommittedEvidenceAt, committed.committedAt)
        XCTAssertEqual(model.latestStorageWatchEvidence?.pathEvent?.rows.first?.label, "kept")
    }

    func testNewestStorageEvidenceRefreshWins() async {
        let model = ScanModel(automaticallyScansStaleResults: false)
        await settleStartup(model)
        let gate = StorageWatchEvidenceReleaseGate()
        let older = evidence(at: Date(timeIntervalSince1970: 100), label: "older")
        let newest = evidence(at: Date(timeIntervalSince1970: 200), label: "newest")

        let olderRefresh = Task { @MainActor in
            await model.refreshStorageWatchEvidence {
                await gate.wait()
                return older
            }
        }
        for _ in 0..<100 {
            if await gate.hasEntered() { break }
            await Task.yield()
        }
        await model.refreshStorageWatchEvidence { newest }
        await gate.release()
        await olderRefresh.value

        XCTAssertEqual(model.storageWatchCommittedEvidenceAt, newest.committedAt)
        XCTAssertEqual(model.latestStorageWatchEvidence?.pathEvent?.rows.first?.label, "newest")
    }

    private func settleStartup(_ model: ScanModel) async {
        let tasks = model.cancelTrackedApplicationTasks()
        for task in tasks { await task.value }
    }

    private func evidence(at capturedAt: Date, label: String) -> StorageWatchEvidenceSnapshot {
        let row = StorageWatchPathSnapshot(
            capturedAt: capturedAt,
            sizeGB: 1,
            status: "ok",
            label: label,
            path: "/tmp/\(label)"
        )
        return StorageWatchEvidenceSnapshot(
            pathEvents: [StorageWatchPathEvent(capturedAt: capturedAt, rows: [row])],
            signalEvents: [],
            committedAt: capturedAt
        )
    }
}
