import XCTest
@testable import MothballCore

/// Every archive this tool writes is the only remaining copy of a
/// workspace it also trashed. So a writer-side schema bump must never be
/// what makes an older archive unreadable, and these tests pin that.
final class ManifestSchemaTests: XCTestCase {

    /// Byte-for-byte what a v1 sidecar looked like: no `historicalPaths`,
    /// no `continuity`. Written as a literal rather than produced by an
    /// old encoder so it keeps testing v1 after v1 stops being buildable.
    private let v1JSON = """
    {
      "archivedAt" : "2026-01-15T09:30:00Z",
      "archivedBy" : "Mothball/0.1",
      "git" : {
        "aheadOfOrigin" : 0,
        "branch" : "main",
        "headSHA" : "abc123",
        "lastCommitDate" : "2026-01-01T00:00:00Z",
        "origin" : "https://github.com/heznpc/example.git",
        "wasDirty" : false
      },
      "originalPath" : "/Users/someone/projects/example",
      "restoreHint" : "git clone https://github.com/heznpc/example.git",
      "schemaVersion" : 1,
      "sizeBytesArchive" : 1024,
      "sizeBytesBefore" : 8192
    }
    """

    func test_v1Manifest_stillDecodes() throws {
        let m = try ArchiveManifest.decoder().decode(
            ArchiveManifest.self, from: Data(v1JSON.utf8)
        )
        XCTAssertEqual(m.schemaVersion, 1)
        XCTAssertEqual(m.originalPath, "/Users/someone/projects/example")
        XCTAssertEqual(m.git.headSHA, "abc123")
    }

    /// A v1 archive knew exactly one location, and it is `originalPath`.
    func test_v1Manifest_historicalPathsDefaultsToOriginalPath() throws {
        let m = try ArchiveManifest.decoder().decode(
            ArchiveManifest.self, from: Data(v1JSON.utf8)
        )
        XCTAssertEqual(m.historicalPaths, ["/Users/someone/projects/example"])
    }

    /// nil, not an empty assessment. "This archive predates the question"
    /// and "a binder ran and found nothing" are different facts, and
    /// synthesising the second from the first would be the same
    /// collapse the gate exists to prevent — just moved to read time.
    func test_v1Manifest_continuityIsNilNotEmpty() throws {
        let m = try ArchiveManifest.decoder().decode(
            ArchiveManifest.self, from: Data(v1JSON.utf8)
        )
        XCTAssertNil(m.continuity)
    }

    func test_restorerAcceptsEverySupportedSchema() {
        XCTAssertTrue(ArchiveManifest.supportedSchemaVersions.contains(1))
        XCTAssertTrue(ArchiveManifest.supportedSchemaVersions.contains(ArchiveManifest.currentSchemaVersion))
    }

    func test_v2Manifest_roundTrips() throws {
        let original = ArchiveManifest(
            schemaVersion: 2,
            archivedAt: Date(timeIntervalSince1970: 1_770_000_000),
            archivedBy: "Mothball/test",
            originalPath: "/now/example",
            sizeBytesBefore: 100,
            sizeBytesArchive: 40,
            git: .init(origin: nil, branch: nil, headSHA: nil,
                       lastCommitDate: nil, aheadOfOrigin: nil, wasDirty: true),
            restoreHint: nil,
            historicalPaths: ["/then/example", "/now/example"],
            continuity: .init(
                assessment: "sealed",
                sessionArchive: "example_2026-08-19T00-00-00.sessions.tar.zst",
                sessions: [
                    SealedSession(
                        provider: .claude, sessionID: "3a4f",
                        artifact: "sessions/claude/3a4f", sha256: "cafe",
                        sizeBytes: 512, fileCount: 3,
                        evidence: [.workingDirectory, .fileAccess], confidence: .medium
                    )
                ],
                overrideReason: nil
            )
        )
        let data = try ArchiveManifest.encoder().encode(original)
        let decoded = try ArchiveManifest.decoder().decode(ArchiveManifest.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.historicalPaths.count, 2)
        XCTAssertEqual(decoded.continuity?.sessions.first?.artifact, "sessions/claude/3a4f")
    }

    /// The override reason is the only thing separating an archive nobody
    /// checked from one that was checked and came back empty, so it has
    /// to survive the round trip.
    func test_overrideReasonSurvivesEncoding() throws {
        let m = ArchiveManifest(
            schemaVersion: 2, archivedAt: Date(timeIntervalSince1970: 0),
            archivedBy: "t", originalPath: "/p", sizeBytesBefore: 1, sizeBytesArchive: 1,
            git: .init(origin: nil, branch: nil, headSHA: nil, lastCommitDate: nil,
                       aheadOfOrigin: nil, wasDirty: false),
            restoreHint: nil,
            continuity: .init(assessment: "overridden-by-user", sessionArchive: nil,
                              sessions: [], overrideReason: "no binder available")
        )
        let decoded = try ArchiveManifest.decoder().decode(
            ArchiveManifest.self, from: ArchiveManifest.encoder().encode(m)
        )
        XCTAssertEqual(decoded.continuity?.overrideReason, "no binder available")
        XCTAssertNotNil(decoded.continuity, "an override must be distinguishable from a v1 silence")
    }
}
