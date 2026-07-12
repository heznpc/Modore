import Foundation
import XCTest
@testable import PCHealthCheckMac

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
