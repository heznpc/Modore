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
            lastExitCode\t1
            lastFinishedAt\t2026-08-12T02:00:05Z
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
}
