import Foundation
import XCTest
@testable import Modore

final class ScanPublicationTests: XCTestCase {
    func testRejectedRunCannotReplaceCanonicalSnapshotAfterReload() throws {
        let root = try privateTemporaryDirectory("rejected")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))

        let accepted = try ScanPublication.prepare(
            in: root,
            expectedParentIdentity: identity
        )
        try writeRun(accepted, scannedAt: "2026-08-26 10:00:00", freeGB: 100)
        XCTAssertTrue(ScanPublication.publish(
            accepted,
            in: root,
            expectedParentIdentity: identity
        ))

        let rejected = try ScanPublication.prepare(
            in: root,
            expectedParentIdentity: identity
        )
        try writeRun(
            rejected,
            scannedAt: "2026-08-26 11:00:00",
            rawScannedAt: "2026-08-26 11:00:01",
            freeGB: 9
        )
        XCTAssertFalse(ScanPublication.outputsAreConsistent(rejected))
        XCTAssertFalse(ScanPublication.publish(
            rejected,
            in: root,
            expectedParentIdentity: identity
        ))
        ScanPublication.discard(rejected)

        let reloaded = ScanResultLoader.load(
            projectRoot: root,
            historyURL: root.appendingPathComponent("history.json"),
            sampleURL: root.appendingPathComponent("samples.tsv")
        )
        XCTAssertEqual(reloaded.content.storage?.freeGB, 100)
        XCTAssertEqual(
            ScanPublication.canonicalDirectory(in: root)?.url.lastPathComponent,
            ScanPublication.currentDirectoryName
        )
    }

    func testAcceptedRunPublishesBothFilesWithOneDirectorySwap() throws {
        let root = try privateTemporaryDirectory("swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))

        let first = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(first, scannedAt: "2026-08-26 10:00:00", freeGB: 100)
        XCTAssertTrue(ScanPublication.publish(
            first,
            in: root,
            expectedParentIdentity: identity
        ))

        let second = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(second, scannedAt: "2026-08-26 12:00:00", freeGB: 80)
        XCTAssertTrue(ScanPublication.publish(
            second,
            in: root,
            expectedParentIdentity: identity
        ))

        let current = try XCTUnwrap(ScanPublication.canonicalDirectory(in: root))
        XCTAssertEqual(try scannedAt(current.url.appendingPathComponent("scan_result.json")),
                       "2026-08-26 12:00:00")
        XCTAssertEqual(try scannedAt(current.url.appendingPathComponent("raw_facts.json")),
                       "2026-08-26 12:00:00")
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".modore-scan-run-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testDeepScanTimestampDoesNotDependOnStorageCollection() throws {
        let root = try privateTemporaryDirectory("no-storage")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let output = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(output, scannedAt: "2026-08-26 12:00:00", freeGB: nil)
        XCTAssertTrue(ScanPublication.publish(
            output,
            in: root,
            expectedParentIdentity: identity
        ))

        let loaded = ScanResultLoader.load(
            projectRoot: root,
            historyURL: root.appendingPathComponent("history.json"),
            sampleURL: root.appendingPathComponent("samples.tsv")
        )
        XCTAssertNotNil(loaded.deepScanAt)
        XCTAssertNil(loaded.content.storage)
    }

    func testCleanupMutationMarkerSurvivesRestartUntilANewScanGenerationPublishes() throws {
        let root = try privateTemporaryDirectory("cleanup-marker")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let first = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(first, scannedAt: "2026-08-26 10:00:00", freeGB: 100)
        XCTAssertTrue(ScanPublication.publish(
            first,
            in: root,
            expectedParentIdentity: identity
        ))

        XCTAssertFalse(ScanPublication.cleanupMutationIsPending(in: root))
        XCTAssertTrue(ScanPublication.markCleanupMutationPending(in: root))
        XCTAssertTrue(ScanPublication.cleanupMutationIsPending(in: root))

        let second = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(second, scannedAt: "2026-08-26 11:00:00", freeGB: 110)
        XCTAssertTrue(ScanPublication.publish(
            second,
            in: root,
            expectedParentIdentity: identity
        ))
        XCTAssertFalse(ScanPublication.cleanupMutationIsPending(in: root))
    }

    func testFailedDirectorySyncRetainsSupersededMarkerGeneration() throws {
        let root = try privateTemporaryDirectory("cleanup-marker-sync-failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = try XCTUnwrap(FilesystemIdentity.directory(at: root))
        let first = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(first, scannedAt: "2026-08-26 10:00:00", freeGB: 100)
        XCTAssertTrue(ScanPublication.publish(
            first,
            in: root,
            expectedParentIdentity: identity
        ))
        XCTAssertTrue(ScanPublication.markCleanupMutationPending(in: root))

        let second = try ScanPublication.prepare(in: root, expectedParentIdentity: identity)
        try writeRun(second, scannedAt: "2026-08-26 11:00:00", freeGB: 110)
        XCTAssertFalse(ScanPublication.publish(
            second,
            in: root,
            expectedParentIdentity: identity,
            synchronizeParent: { _ in false }
        ))

        let visible = try XCTUnwrap(ScanPublication.canonicalDirectory(in: root))
        XCTAssertEqual(visible.identity, second.directoryIdentity)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: second.directoryURL
                .appendingPathComponent(".cleanup-mutation-pending").path
        ))

        // The pipeline's normal deferred discard is keyed to the new staged
        // inode and therefore must not erase the swapped-out old generation.
        ScanPublication.discard(second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.directoryURL.path))
    }

    private func privateTemporaryDirectory(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("modore-scan-publication-\(suffix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func writeRun(
        _ output: StagedScanOutput,
        scannedAt: String,
        rawScannedAt: String? = nil,
        freeGB: Double?
    ) throws {
        var sections: [String: Any] = [:]
        if let freeGB {
            sections["storage"] = [
                "volume": [
                    "mount": "/",
                    "freeGB": freeGB,
                    "usedGB": 100 - freeGB,
                    "totalGB": 100,
                    "usePercent": 100 - freeGB,
                    "risk": "safe",
                ],
                "cleanupCandidates": [],
            ]
        }
        let scan: [String: Any] = [
            "schemaVersion": "1.0",
            "scannedAt": scannedAt,
            "sections": sections,
        ]
        let raw: [String: Any] = [
            "schemaVersion": "1.0",
            "scannedAt": rawScannedAt ?? scannedAt,
            "sections": [:],
        ]
        try JSONSerialization.data(withJSONObject: scan).write(
            to: output.scanResultURL,
            options: .atomic
        )
        try JSONSerialization.data(withJSONObject: raw).write(
            to: output.rawFactsURL,
            options: .atomic
        )
    }

    private func scannedAt(_ url: URL) throws -> String? {
        let data = try Data(contentsOf: url)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return root?["scannedAt"] as? String
    }
}
